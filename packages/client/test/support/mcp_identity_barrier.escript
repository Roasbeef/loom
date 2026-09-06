#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
%%
%% This test-only stdio peer reports an actual initialize request, then keeps
%% reading without answering it. EOF retires the peer when its daemon dies.
%% The production handshake still has its ordinary timeout: only post-crash
%% Reserved metadata plus SQLite identity prove the intended durable boundary.
%% A separate fixture-owned file enables normal replies on the recovered VM.

main([Marker, Release]) ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    %% EOF is the ordinary exit. The independent watchdog also bounds a peer
    %% whose parent or cleanup unexpectedly keeps the input pipe alive.
    {ok, _} = timer:apply_after(120000, erlang, halt, [2]),
    loop(Marker, Release).

loop(Marker, Release) ->
    case io:get_line(standard_io, "") of
        eof -> halt(0);
        {error, _} -> halt(1);
        Line ->
            dispatch(json:decode(string:trim(Line)), Marker, Release),
            loop(Marker, Release)
    end.

dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}, Marker, Release) ->
    %% Rename publishes a complete PID rather than exposing a partial write to
    %% the coordinator. Process creation alone never writes this observation.
    ok = file:write_file(Marker ++ ".pending", [os:getpid(), "\n"]),
    ok = file:rename(Marker ++ ".pending", Marker),
    case file:read_file(Release) of
        {ok, <<"answer">>} ->
            reply(Id, #{
                <<"protocolVersion">> => <<"2025-06-18">>,
                <<"capabilities">> => #{<<"tools">> => #{}},
                <<"serverInfo">> => #{
                    <<"name">> => <<"identity-barrier">>,
                    <<"version">> => <<"1">>
                }
            });
        {error, enoent} -> ok
    end;
dispatch(#{<<"method">> := <<"tools/list">>, <<"id">> := Id}, _Marker, _Release) ->
    reply(Id, #{<<"tools">> => []});
dispatch(#{<<"method">> := <<"notifications/initialized">>}, _Marker, _Release) ->
    ok.

reply(Id, Result) ->
    io:put_chars(standard_io, [json:encode(#{
        <<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result
    }), <<"\n">>]).
