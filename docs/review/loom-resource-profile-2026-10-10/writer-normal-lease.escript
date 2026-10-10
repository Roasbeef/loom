#!/usr/bin/env escript
%%! +S 2 +SDcpu 1 +SDio 1
%% Run only in a disposable VM. The callback promotes synthetic commit garbage
%% to expose idle heap capacity; it does not replay the installed workload.
%% Arguments are the runtime build directory and saved baseline/candidate BEAMs.
-mode(compile).
main([Build, Baseline, Candidate]) ->
    lists:foreach(fun code:add_patha/1,filelib:wildcard(filename:join([Build,"*","ebin"]))),
    {ok,_}=application:ensure_all_started(runtime),
    Forms=forms(Baseline),
    CandidateForms=forms(Candidate),
    TestForms=forms(filename:join([Build,"runtime","ebin","runtime@writer_renewal_test.beam"])),
    load(TestForms,[binary,export_all]),
    lists:foreach(fun(Mode)->
        F=case Mode of baseline->Forms;candidate->CandidateForms end,
        load(F,[binary]),
        run(Mode)
    end,[baseline,candidate]).
forms(Path)->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Path,[abstract_code]),Forms.
load(Forms,Options)->
    {ok,M,B}=compile:forms(Forms,Options),
    code:purge(M),{module,M}=code:load_binary(M,"disposable-writer-residency",B).
run(Mode)->
    Parent=self(),
    Session='runtime@writer_renewal_test':leased_session(20000,fun()->Parent!{renew,erlang:monotonic_time(millisecond)},{ok,nil} end),
    {ok,Registry}='weft@registry':start(),
    Name='weft@registry':new_address(Registry),
    After=fun(1)->
        Chunk=lists:seq(1,500000),
        erlang:garbage_collect(self(),[{type,minor}]),
        erlang:garbage_collect(self(),[{type,minor}]),
        Parent!{allocated,erlang:phash2(Chunk)},nil;
        (_)->nil
    end,
    {ok,Started}='runtime@writer':start({options,Session,After,[]},Name),
    Pid=element(2,Started),unlink(Pid),
    T0=erlang:monotonic_time(millisecond),
    {ok,_}='runtime@writer':commit(Name,{tx,[],[]}),
    receive {allocated,_}->ok after 1000->error(no_commit) end,
    io:format("~p busy ~p~n",[Mode,process_info(Pid,[memory,total_heap_size,current_function])]),
    {reductions,B0}=process_info(Pid,reductions),
    Busy0=erlang:monotonic_time(microsecond),
    lists:foreach(fun(_)->{ok,_}='runtime@writer':commit(Name,{tx,[],[]}) end,lists:seq(1,1000)),
    BusyUs=erlang:monotonic_time(microsecond)-Busy0,
    {reductions,B1}=process_info(Pid,reductions),
    io:format("~p busy_commits=1000 busy_us=~p busy_reductions=~p~n",[Mode,BusyUs,B1-B0]),
    receive after 11000->ok end,
    io:format("~p idle ~p~n",[Mode,process_info(Pid,[memory,total_heap_size,current_function])]),
    {reductions,R0}=process_info(Pid,reductions),
    Wake0=erlang:monotonic_time(microsecond),
    {ok,_}='runtime@writer':stats(Name),
    WakeUs=erlang:monotonic_time(microsecond)-Wake0,
    {reductions,R1}=process_info(Pid,reductions),
    io:format("~p wake_us=~p wake_reductions=~p~n",[Mode,WakeUs,R1-R0]),
    receive after 11000->ok end,
    Times=renewals([]),
    io:format("~p renewed_ms=~p alive=~p after_wake=~p~n",[Mode,[T-T0||T<-Times],is_process_alive(Pid),process_info(Pid,[memory,current_function])]),
    exit(Pid,kill),{ok,nil}='weft@registry':stop(Registry).
renewals(Acc)->receive {renew,T}->renewals([T|Acc]) after 0->lists:reverse(Acc) end.
