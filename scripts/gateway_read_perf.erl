%% Real SQLite reads and the unchanged gateway message path are measured together.
%% This module runs only in a disposable fixture VM, never on the live daemon.
-module(gateway_read_perf).
-export([main/1]).

main([Label]) ->
    try
        {ok, _} = application:ensure_all_started(client),
        io:format("VM otp=~s word_bytes=~p schedulers=~p~n",
            [erlang:system_info(otp_release), erlang:system_info(wordsize),
             erlang:system_info(schedulers_online)]),
        lists:foreach(fun(Count) -> trial(Label, Count) end, [1, 8, 64, 128]),
        halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n", [C,R,S]), halt(1)
    end.

trial(Label, Count) ->
    Path = list_to_binary("build/gateway_read_perf/session-" ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    {ok, {Session, RetireStore, Transfer}} = 'session@session':open_sqlite_custody(
        Path, <<"gateway-perf">>, 30000, 'core@clock':fixed(1000)),
    {ok, SqlitePid} = Transfer(),
    {fixture, Options, RetireAuxiliary} = 'client@gateway_read_fixture':open(Session, Count),
    {Hub, GatewayPid} = 'client@gateway_read_fixture':start(Options),
    try
        N = 200,
        Run = fun() -> repeat(N, Hub) end,
        repeat(10, Hub),
        BeforeMemory = memory(GatewayPid, SqlitePid),
        R0 = reductions(GatewayPid, SqlitePid),
        {Cpu0, _} = statistics(runtime),
        {Us, _} = timer:tc(Run),
        {Cpu1, _} = statistics(runtime),
        R1 = reductions(GatewayPid, SqlitePid),
        AfterMemory = memory(GatewayPid, SqlitePid),
        %% Count native SQL calls in a separate window, after startup and warmup.
        erlang:trace_pattern({esqlite3, q, 3}, true, [call_count]),
        Run(),
        {call_count, SqlCalls} = erlang:trace_info({esqlite3, q, 3}, call_count),
        erlang:trace_pattern({esqlite3, q, 3}, false, [call_count]),
        {ok, P} = tprof:start(#{type => call_memory, session => gateway_read_perf}),
        Words = try
            tprof:set_pattern(P, 'client@gateway', handle, 2),
            tprof:set_pattern(P, 'storage@sqlite', handle_open, 2),
            tprof:enable_trace(P, GatewayPid, #{set_on_spawn => false}),
            tprof:enable_trace(P, SqlitePid, #{set_on_spawn => false}),
            Run(),
            tprof:pause(P),
            #{all := {_, W, _}} = tprof:inspect(tprof:collect(P), total,
                {measurement, descending}),
            W
        after tprof:stop(P) end,
        io:format("RESULT ~s strands=~p pulls=~p us=~p cpu_ms=~p reductions=~p sql_calls=~p words=~p bytes=~p~n",
            [Label, Count, N, Us, Cpu1-Cpu0, R1-R0, SqlCalls,
             Words, Words * erlang:system_info(wordsize)]),
        io:format("MEMORY strands=~p before=~p after=~p~n",
            [Count, BeforeMemory, AfterMemory])
    after
        exit(GatewayPid, kill),
        nil = RetireAuxiliary(),
        {ok, nil} = RetireStore(),
        %% Only this benchmark's synthetic database files are removed.
        [file:delete(<<Path/binary, Suffix/binary>>) ||
            Suffix <- [<<>>, <<"-wal">>, <<"-shm">>]]
    end.

repeat(0, _) -> ok;
repeat(N, Hub) ->
    nil = 'client@gateway_read_fixture':pull(Hub),
    repeat(N - 1, Hub).

reductions(Gateway, Sqlite) ->
    {reductions, G} = process_info(Gateway, reductions),
    {reductions, S} = process_info(Sqlite, reductions),
    G + S.

memory(Gateway, Sqlite) ->
    #{gateway => process_info(Gateway, [memory, total_heap_size]),
      sqlite => process_info(Sqlite, [memory, total_heap_size]),
      vm => erlang:memory([total, processes, binary]), rss_kib => rss()}.

rss() ->
    case string:to_integer(string:trim(os:cmd("ps -o rss= -p " ++ os:getpid()))) of
        {Value, []} -> Value;
        _ -> unavailable
    end.
