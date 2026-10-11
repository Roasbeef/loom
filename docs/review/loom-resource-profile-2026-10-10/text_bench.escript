#!/usr/bin/env escript
%%! +S 1:1 +SDcpu 1 +SDio 1
-mode(compile).
main([Build, Baseline]) ->
    lists:foreach(fun code:add_patha/1, filelib:wildcard(filename:join([Build,"*","ebin"]))),
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} = beam_lib:chunks(Baseline,[abstract_code]),
    Old = hygiene_baseline,
    Renamed = [case F of {attribute,L,module,_} -> {attribute,L,module,Old}; _ -> F end || F <- Forms],
    {ok,Old,Binary} = compile:forms(Renamed,[binary]),
    {module,Old} = code:load_binary(Old,Baseline,Binary),
    New = 'session_view@text_hygiene',
    {module,New} = code:ensure_loaded(New),
    io:format("otp=~s erts=~s word_bytes=~p~n",[erlang:system_info(otp_release),erlang:system_info(version),erlang:system_info(wordsize)]),
    differential(Old,New,0,0),
    Samples = [{ascii,binary:copy(<<"source line and ordinary status text\n">>,30)},
               {unicode,binary:copy(unicode:characters_to_binary("漢字 wörd 👍🏽 text\n"),30)},
               {dirty_tail,<<(binary:copy(<<"plain text ">>,100))/binary,27,"[31mred",27,"[0m">>},
               {dirty_front,<<27,"[31m",(binary:copy(<<"plain text ">>,100))/binary>>}],
    lists:foreach(fun({Shape,Text}) ->
        lists:foreach(fun(M) -> measure(M,Shape,Text) end,[Old,New])
    end,Samples),
    Big = binary:copy(<<"a">>,1048576),
    Part = binary:part(Big,700,200),
    lists:foreach(fun(M) ->
        Out = M:multiline(Part),
        200 = byte_size(Out),
        200 = binary:referenced_byte_size(Out),
        io:format("~p owned_slice_bytes=~p~n",[M,binary:referenced_byte_size(Out)])
    end,[Old,New]).
differential(_Old,_New,16#110000,Count) -> io:format("unicode_differential_cases=~p~n",[Count]);
differential(Old,New,N,Count) when N >= 16#D800,N =< 16#DFFF -> differential(Old,New,16#E000,Count);
differential(Old,New,N,Count) ->
    C = <<N/utf8>>,
    T = <<"clean ",C/binary,230,188,162," suffix">>,
    A = Old:multiline(T),
    A = New:multiline(T),
    differential(Old,New,N+1,Count+1).
measure(M,Shape,Text) ->
    loop(M,Text,20),
    lists:foreach(fun(_) ->
        erlang:garbage_collect(),
        {reductions,R0}=process_info(self(),reductions),
        T0=erlang:monotonic_time(microsecond),
        loop(M,Text,2000),
        Elapsed=erlang:monotonic_time(microsecond)-T0,
        {reductions,R1}=process_info(self(),reductions),
        io:format("~p ~p calls=2000 bytes=~p us=~p reductions=~p~n",[M,Shape,byte_size(Text),Elapsed,R1-R0])
    end,lists:seq(1,5)),
    {ok,S}=tprof:start(#{type=>call_memory}),
    try
        tprof:set_pattern(S,M,'_','_'),
        tprof:enable_trace(S,self(),#{set_on_spawn=>false}),
        loop(M,Text,200),
        tprof:pause(S),
        {call_memory,Rows}=tprof:collect(S),
        Words=lists:sum([W || {_,_,_,Pids} <- Rows,{Pid,_,W} <- Pids,Pid=:=self()]),
        io:format("~p ~p allocation_calls=200 words=~p bytes=~p~n",[M,Shape,Words,Words*erlang:system_info(wordsize)])
    after tprof:stop(S) end.
loop(_,_,0)->ok;
loop(M,Text,N)-> M:multiline(Text),loop(M,Text,N-1).
