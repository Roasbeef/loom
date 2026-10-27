%% Full synthetic Anthropic request encoding against an exact saved baseline.
%% Correctness checks stay outside untraced timing; root-only call_memory runs
%% separately. No daemon state, network request or live GC is involved.
-module(anthropic_merge_perf).
-export([main/1]).

main([Baseline]) ->
    try
        {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Baseline,[abstract_code]),
        Renamed=[case F of {attribute,L,module,_}->{attribute,L,module,anthropic_merge_baseline}; X->X end || F<-Forms],
        {ok,anthropic_merge_baseline,Bin}=compile:forms(Renamed,[binary]),
        {module,anthropic_merge_baseline}=code:load_binary(anthropic_merge_baseline,"baseline",Bin),
        io:format("VM otp=~s word_bytes=~p schedulers=~p~n",[erlang:system_info(otp_release),erlang:system_info(wordsize),erlang:system_info(schedulers_online)]),
        lists:foreach(fun(Count)->
            lists:foreach(fun({Layout,Request})->
                lists:foreach(fun(Prefix)->matched(Layout,Count,Request,Prefix) end,[none,{some,2 + Count div 2}])
            end,[{batch,legal_request(batch,'provider@anthropic_merge_fixture':batch(Count))},
                 {alternating,legal_request(alternating,'provider@anthropic_merge_fixture':alternating(Count))}])
        end,[1,8,64,128]),halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n",[C,R,S]),halt(1) end.

%% Include the initiating prompt and every matching tool call, rather than
%% attributing a complete-request percentage to a result-only microfixture.
legal_request(Layout,Request) ->
    Messages=element(4,Request),
    Prompt={user_message,[{user_text,<<"Inspect the fixture files">>,none}],1,none},
    WithCalls=case Layout of
        batch ->
            Template=hd(element(4,'provider@anthropic_merge_fixture':alternating(1))),
            [calling(Template,Messages)|Messages];
        alternating -> paired_calls(Messages)
    end,
    setelement(4,Request,[Prompt|WithCalls]).

paired_calls([]) -> [];
paired_calls([Assistant,Result|Rest]) ->
    [calling(Assistant,[Result]),Result|paired_calls(Rest)].

calling(Assistant,Results) ->
    Calls=[{assistant_tool_call,{tool_call,element(2,Result),<<"fs_read">>,
        {object,[{<<"path">>,{string,<<"fixture.txt">>}}]},none,none}} || Result<-Results],
    setelement(10,setelement(2,Assistant,Calls),tool_use).

matched(Layout,Count,Request,Prefix) ->
    Expected=build(anthropic_merge_baseline,Request,Prefix),
    Expected=build('provider@adapter@anthropic',Request,Prefix),
    io:format("PARITY layout=~s results=~p prefix=~p bytes=~p~n",[Layout,Count,Prefix,byte_size(element(5,Expected))]),
    lists:foreach(fun(Round)->
        Modules=case Round rem 2 of 1->[anthropic_merge_baseline,'provider@adapter@anthropic'];0->['provider@adapter@anthropic',anthropic_merge_baseline] end,
        lists:foreach(fun(Module)->trial(Layout,Count,Request,Prefix,Round,Module) end,Modules)
    end,lists:seq(1,4)).

build(Module,Request,Prefix) ->
    Module:build_request_with_prefix(<<"https://example.invalid">>,<<"fixture-key">>,
        'provider@anthropic_merge_fixture':resolved(),Request,Prefix).

trial(Layout,Count,Request,Prefix,Round,Module) ->
    Run=fun()->build(Module,Request,Prefix) end,
    N=500,
    {Us,CpuMs,Reductions}=isolated(fun()->
        repeat(20,Run),
        {reductions,R0}=process_info(self(),reductions),
        {Cpu0,_}=statistics(runtime),
        {Elapsed,_}=timer:tc(fun()->repeat(N,Run) end),
        {Cpu1,_}=statistics(runtime),
        {reductions,R1}=process_info(self(),reductions),
        {Elapsed,Cpu1-Cpu0,R1-R0}
    end),
    Words=isolated(fun()->
        repeat(20,Run),
        {ok,P}=tprof:start(#{type=>call_memory,session=>anthropic_merge_perf}),
        try
            tprof:set_pattern(P,Module,build_request_with_prefix,5),
            tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
            repeat(N,Run),tprof:pause(P),
            #{all:={_,W,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),W
        after tprof:stop(P) end
    end),
    io:format("RESULT layout=~s results=~p prefix=~p round=~p module=~s calls=~p us=~p cpu_ms=~p reductions=~p allocated_words=~p allocated_bytes=~p~n",[Layout,Count,Prefix,Round,Module,N,Us,CpuMs,Reductions,Words,Words*erlang:system_info(wordsize)]).

%% A prior allocation trace must not select the next timing trial's heap/GC
%% history. Both measurements get a fresh disposable worker and equal warmup.
isolated(Measure) ->
    Parent=self(),Tag=make_ref(),
    {Pid,Monitor}=spawn_monitor(fun()->Parent!{Tag,Measure()} end),
    receive
        {Tag,Value}->
            receive
                {'DOWN',Monitor,process,Pid,normal}->Value;
                {'DOWN',Monitor,process,Pid,Reason}->error({measurement_exit,Reason})
            end;
        {'DOWN',Monitor,process,Pid,Reason}->error({measurement_exit,Reason})
    end.

repeat(0,_) -> ok;
repeat(N,Run) -> Run(),repeat(N-1,Run).
