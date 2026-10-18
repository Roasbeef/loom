%% Run the actual fixture and package in an isolated VM with no live daemon.
-module(satellite_worker_perf).
-export([main/0]).
main() ->
    {ok, _} = application:ensure_all_started(codemode),
    Path = code:which('codemode@satellite_test'),
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Path, [abstract_code]),
    {ok, Module, Binary} = compile:forms(Forms, [export_all, binary]),
    {module, Module} = code:load_binary(Module, Path, Binary),
    lists:foreach(fun(N) ->
        {StartupBytes, Bytes} = 'codemode@satellite_test':worker_memory_with_limits(N),
        erlang:garbage_collect(),
        {Cpu0, _} = erlang:statistics(runtime),
        {Red0, _} = erlang:statistics(reductions),
        {Us, _} = timer:tc(fun() ->
            lists:foreach(fun(_) ->
                'codemode@satellite_test':worker_memory_with_limits(N)
            end, lists:seq(1, 50))
        end),
        {Cpu1, _} = erlang:statistics(runtime),
        {Red1, _} = erlang:statistics(reductions),
        io:format("WORKER ceilings=~p startup_bytes=~p bytes=~p repetitions=50 elapsed_us=~p vm_cpu_ms=~p reductions=~p~n",
            [N, StartupBytes, Bytes, Us, Cpu1-Cpu0, Red1-Red0])
    end, [0, 5000]),
    halt().
