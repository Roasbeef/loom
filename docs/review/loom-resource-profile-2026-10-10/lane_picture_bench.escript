#!/usr/bin/env escript
%%! +S 1:1 +SDcpu 1 +SDio 1
-mode(compile).
main([Build, Mode, Beam]) ->
    lists:foreach(fun code:add_patha/1,filelib:wildcard(filename:join([Build,"*","ebin"]))),
    M='web_view@view@lane',
    {ok,Bin}=file:read_file(Beam),
    {module,M}=code:load_binary(M,Beam,Bin),
    {ok,_}=application:ensure_all_started(web_view),
    Page0='web_view@component':new(page_fixture:start()),
    Page=lane_fixture:opened('web_view@component':apply(Page0,[lane_fixture:heavy(30,1000)])),
    View='web_view@operator_page':view(Page),
    Cache=lane_memo_ffi:first(View),
    Html='lustre@element':to_string(View),
    io:format("html_sha256=~s~n",[binary:encode_hex(crypto:hash(sha256,Html))]),
    io:format("mode=~s page_flat_bytes=~p initial_view_sha256=~s~n",[Mode,erts_debug:flat_size(Page)*8,binary:encode_hex(crypto:hash(sha256,term_to_binary(View)))]),
    lists:foreach(fun(_) ->
        erlang:garbage_collect(),
        {reductions,R0}=process_info(self(),reductions),
        T0=erlang:monotonic_time(microsecond),
        {Patch,_}=loop(Page,View,Cache,1000),
        Us=erlang:monotonic_time(microsecond)-T0,
        {reductions,R1}=process_info(self(),reductions),
        io:format("mode=~s renders=1000 us=~p reductions=~p patch=~s~n",[Mode,Us,R1-R0,Patch])
    end,lists:seq(1,5)),
    {ok,S}=tprof:start(#{type=>call_memory}),
    try
        Mods=['web_view@operator_page','web_view@view@lane','session_view@transcript_image','lustre@vdom@diff'],
        lists:foreach(fun(Mod)->{module,Mod}=code:ensure_loaded(Mod),tprof:set_pattern(S,Mod,'_','_') end,Mods),
        tprof:enable_trace(S,self(),#{set_on_spawn=>false}),
        loop(Page,View,Cache,100),
        tprof:pause(S),
        {call_memory,Rows}=tprof:collect(S),
        lists:foreach(fun(Mod)->
            Words=lists:sum([W || {MM,_,_,Pids}<-Rows,MM=:=Mod,{Pid,_,W}<-Pids,Pid=:=self()]),
            io:format("mode=~s module=~p renders=100 allocated_bytes=~p~n",[Mode,Mod,Words*8])
        end,Mods)
    after tprof:stop(S) end.
loop(Page,View,Cache,1) -> lane_memo_ffi:patch_text(Cache,View,'web_view@operator_page':view(Page));
loop(Page,View,Cache,N) ->
    Next='web_view@operator_page':view(Page),
    {_,NextCache}=lane_memo_ffi:patch_text(Cache,View,Next),
    loop(Page,Next,NextCache,N-1).
