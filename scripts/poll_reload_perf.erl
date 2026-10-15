%% Hold the same SQLite-backed summary while measuring checkpoint work.
%% CPU and allocation run separately; memory figures are uncollected capacity.
-module(poll_reload_perf).
-export([main/1]).
-include("runtime@api_Runtime.hrl").

main([Label, Mode]) ->
    Path = "build/poll_reload_perf/session.db",
    ok = filelib:ensure_dir(Path),
    lists:foreach(fun(Suffix) -> file:delete(Path ++ Suffix) end,
        ["", "-wal", "-shm"]),
    {ok, Session} = 'session@session':open_sqlite(
        list_to_binary(Path), <<"poll-perf">>, 30000, 'core@clock':fixed(1000)),
    io:format("VM label=~s mode=~s otp=~s word_bytes=~p schedulers=~p~n",
        [Label, Mode, erlang:system_info(otp_release),
         erlang:system_info(wordsize), erlang:system_info(schedulers_online)]),
    'support@held_operation':run(Session, summary, 200,
        fun(Held) -> observe(Held, Label, Mode) end),
    halt().

observe({held, Runtime, Counters} = Held, Label, Mode) ->
    {answered, nil} = 'support@held_operation':wait_for_reads(Held, 3),
    %% The generated header keeps the lookup tied to the compiled runtime.
    Tree = Runtime#runtime.tree,
    {ok, Subject} = 'runtime@supervisor':strand_subject(Tree, <<"main">>),
    {ok, Driver} = 'gleam@erlang@process':subject_owner(Subject),
    BeforeMemory = erlang:memory(),
    BeforeDriver = process_info(Driver, [memory, total_heap_size, heap_size]),
    BeforeRss = rss(),
    BeforeControl = 'support@recorder':read(Counters, <<"control">>),
    BeforePreparation = 'support@recorder':read(Counters, <<"preparation">>),
    Profiler = start_profile(Mode),
    {CpuBefore, _} = statistics(runtime),
    {ReductionsBefore, _} = statistics(reductions),
    Started = erlang:monotonic_time(microsecond),
    timer:sleep(3000),
    Control = 'support@recorder':read(Counters, <<"control">>) - BeforeControl,
    Preparation = 'support@recorder':read(Counters, <<"preparation">>)
        - BeforePreparation,
    Elapsed = erlang:monotonic_time(microsecond) - Started,
    {CpuAfter, _} = statistics(runtime),
    {ReductionsAfter, _} = statistics(reductions),
    stop_profile(Profiler),
    AfterMemory = erlang:memory(),
    AfterDriver = process_info(Driver, [memory, total_heap_size, heap_size]),
    AfterRss = rss(),
    io:format("MEASURE ~s elapsed_us=~p cpu_ms=~p reductions=~p control_reads=~p preparation_lists=~p~n",
        [Label, Elapsed, CpuAfter - CpuBefore,
         ReductionsAfter - ReductionsBefore, Control, Preparation]),
    io:format("MEMORY ~s before=~p after=~p driver_before=~p driver_after=~p rss_kib_before=~p rss_kib_after=~p~n",
        [Label, memory(BeforeMemory), memory(AfterMemory),
         BeforeDriver, AfterDriver, BeforeRss, AfterRss]),
    nil.

start_profile("cpu") -> none;
start_profile("allocation") ->
    {module, 'runtime@strand_runtime'} = code:ensure_loaded('runtime@strand_runtime'),
    {module, 'storage@internal@register_cache'} = code:ensure_loaded('storage@internal@register_cache'),
    {ok, Profiler} = tprof:start(#{type => call_memory, session => poll_reload_perf}),
    tprof:set_pattern(Profiler, 'runtime@strand_runtime', load_operation, 4),
    tprof:set_pattern(Profiler, 'storage@internal@register_cache', decode_blob, 1),
    tprof:enable_trace(Profiler, all, #{set_on_spawn => true}),
    Profiler.

stop_profile(none) -> ok;
stop_profile(Profiler) ->
    tprof:pause(Profiler),
    io:format("ALLOCATION ~p~n", [tprof:inspect(tprof:collect(Profiler),
        total, {measurement, descending})]),
    tprof:stop(Profiler).

memory(Values) ->
    [{Key, proplists:get_value(Key, Values)} || Key <-
        [total, processes, processes_used, binary, ets]].

rss() ->
    case string:trim(os:cmd("ps -o rss= -p " ++ os:getpid())) of
        [] -> unavailable;
        Text ->
            case string:to_integer(Text) of
                {Value, []} -> Value;
                _ -> unavailable
            end
    end.
