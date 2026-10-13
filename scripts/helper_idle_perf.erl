%% Isolated real-helper measurements. No daemon endpoint or store is opened.
-module(helper_idle_perf).
-export([main/0]).

main() ->
    [Root, Baseline, Round0, Lifecycle] = init:get_plain_arguments(),
    Round = list_to_integer(Round0),
    rename_baseline(Baseline),
    {ok, _} = application:ensure_all_started(broker),
    io:format("META otp=~s schedulers=~p round=~p lifecycle=~s~n",
              [erlang:system_info(otp_release), erlang:system_info(schedulers_online), Round, Lifecycle]),
    Order = case Round rem 2 of 0 -> [candidate, baseline]; 1 -> [baseline, candidate] end,
    lists:foreach(fun(Version) -> latency(Root, Version) end, Order),
    Repeats = case Lifecycle of "production" -> 1; "accelerated" -> 3 end,
    lists:foreach(fun(_) ->
        lists:foreach(fun(Version) -> lifecycle(Root, Version, Lifecycle) end, Order)
    end, lists:seq(1, Repeats)),
    halt(0).

%% Renaming the module attribute keeps local calls local. A remote self-call
%% would invalidate comparison by jumping into the candidate and is refused.
rename_baseline(Path) ->
    {ok, {Original, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Path, [abstract_code]),
    false = remote_self_call(Forms, Original),
    Renamed = [case Form of {attribute, L, module, Original} ->
                    {attribute, L, module, helper_idle_baseline}; _ -> Form end || Form <- Forms],
    {ok, helper_idle_baseline, Binary} = compile:forms(Renamed, [binary, return_errors]),
    {module, helper_idle_baseline} = code:load_binary(helper_idle_baseline, Path, Binary).

remote_self_call({remote, _, {atom, _, M}, _}, M) -> true;
remote_self_call(T, M) when is_tuple(T) -> remote_self_call(tuple_to_list(T), M);
remote_self_call([H | T], M) -> remote_self_call(H, M) orelse remote_self_call(T, M);
remote_self_call(_, _) -> false.

module(baseline) -> helper_idle_baseline;
module(candidate) -> 'broker@exec'.

%% Each probe has a unique workspace and transient policy directory. The same
%% binary and policy serve both versions; only pool ownership code differs.
open(Root, Version, TimerMode) ->
    M = module(Version),
    Dir = filename:join([Root, "packages/broker/build/helper-idle-perf",
                        atom_to_list(Version) ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join([Dir, "work", "placeholder"])),
    BDir = unicode:characters_to_binary(Dir),
    Policy = {sandbox_policy, [<<BDir/binary, "/work">>], [<<"/">>], [], network_off,
              {limits, 30, 60, 536870912, 64, 8388608, 1048576},
              [<<"PATH">>], scratch_tmpfs, []},
    Config = {spawn_config, unicode:characters_to_binary(filename:join(Root, "packages/sandbox/loom-exec")),
              <<"/bin/sh">>, Policy, [], <<BDir/binary, "/tmp">>, 5000, 3000, 0},
    Spawn = fun() -> M:prepare_helper(Config) end,
    {ok, Pool} = case {Version, TimerMode} of
        {candidate, accelerated} ->
            Source = {injected, fun(_RequestedDelay, Wake) ->
                spawn(fun() -> timer:sleep(1000), Wake() end), nil
            end},
            M:start_pool_with_timers(4, Spawn, Source);
        _ -> M:start_pool(4, Spawn)
    end,
    {M, Pool, BDir}.

checkout({M, Pool, _}) -> {ok, H} = M:checkout(Pool, 15000), H.
checkin({M, Pool, _}, H) -> M:checkin(Pool, H).
census({M, Pool, _}) -> {ok, C} = M:pool_census(Pool, 5000), C.
close({M, Pool, _}) ->
    {ok, nil} = M:close_pool(Pool, 10000),
    M:stop_pool(Pool).

warm(P) ->
    Helpers = [checkout(P) || _ <- lists:seq(1, 4)],
    lists:foreach(fun(H) -> _ = run_helper(P, H) end, Helpers),
    lists:foreach(fun(H) -> checkin(P, H) end, Helpers),
    {pool_census, 4, 4, 0, 0, 0, 0, _, _} = census(P),
    Helpers.

%% Every measured warm iteration includes the asynchronous checkin followed
%% by the next synchronous checkout. A final census fences the last return.
latency(Root, Version) ->
    P = open(Root, Version, production),
    Helpers = warm(P),
    M = module(Version),
    {_, Pool, _} = P,
    Actors = [M:pool_pid(Pool) | [M:pid(H) || H <- Helpers]],
    lists:foreach(fun(_) -> cycle(P) end, lists:seq(1, 100)),
    lists:foreach(fun(Batch) ->
        {CpuBefore, _} = erlang:statistics(runtime),
        ReductionsBefore = actor_reductions(Actors),
        Started = now_us(),
        lists:foreach(fun(_) -> cycle(P) end, lists:seq(1, 2000)),
        _ = census(P),
        Elapsed = now_us() - Started,
        {CpuAfter, _} = erlang:statistics(runtime),
        Reductions = actor_reductions(Actors) - ReductionsBefore,
        io:format("WARM version=~p batch=~p n=2000 total_us=~p vm_cpu_ms=~p actor_reductions=~p~n",
                  [Version, Batch, Elapsed, CpuAfter - CpuBefore, Reductions])
    end, lists:seq(1, 7)),
    lists:foreach(fun(Index) ->
        Started = now_us(),
        Result = command(P),
        Elapsed = now_us() - Started,
        io:format("CALL version=~p sample=~p elapsed_us=~p degraded=~p enforcement=~0p~n",
                  [Version, Index, Elapsed, element(9, Result), element(8, Result)])
    end, lists:seq(1, 35)),
    close(P).

cycle(P) -> H = checkout(P), checkin(P, H).

%% This is an actual jailed execution; success and the helper's reported
%% enforcement are witnessed, rather than treating acceptance as completion.
command(P) ->
    H = checkout(P),
    Result = run_helper(P, H),
    checkin(P, H),
    Result.

run_helper({M, _, Dir}, H) ->
    Events = 'gleam@erlang@process':new_subject(),
    Request = {exec_request, [<<"/usr/bin/true">>], [{<<"PATH">>, <<"/usr/bin:/bin">>}],
               <<Dir/binary, "/work">>, none, <<"isolated-idle-benchmark">>, best_effort},
    {ok, nil} = M:run(H, Request, Events, 10000),
    await_result(Events).

await_result(Events) ->
    case 'gleam@erlang@process':'receive'(Events, 15000) of
        {ok, {output, _, _, _, _}} -> await_result(Events);
        {ok, {exited, R}} ->
            0 = element(2, R),
            false = element(11, R),
            false = element(12, R),
            Layers = element(8, R),
            case os:type() of
                {unix, darwin} -> true = lists:member(<<"seatbelt">>, Layers),
                                  true = lists:member(<<"seatbelt-net">>, Layers);
                {unix, linux} -> true = lists:member(<<"bwrap">>, Layers)
            end,
            R;
        Other -> error({execution_not_successful, Other})
    end.

%% The first round uses the shipped 60-second wall-clock timer. Other rounds
%% accelerate ONLY the timer source; they retain the exact retirement path.
%% A pool census proves both native and helper-actor retirement boundaries.
lifecycle(Root, Version, Mode) ->
    TimerMode = case Mode of "production" -> production; "accelerated" -> accelerated end,
    P = {M, Pool, _} = open(Root, Version, TimerMode),
    BeforePorts = native_pids(),
    Helpers = warm(P),
    Pids = native_pids() -- BeforePorts,
    4 = length(Pids),
    RssBefore = [{Pid, rss_kib(Pid)} || Pid <- Pids],
    true = lists:all(fun({_, Rss}) -> Rss > 0 end, RssBefore),
    PoolPid = M:pool_pid(Pool),
    ActorPids = [PoolPid | [M:pid(H) || H <- Helpers]],
    BeamBefore = actor_memory(ActorPids),
    IdleStarted = now_us(),
    case Version of
        candidate -> await_empty(P, now_us() + 75000000);
        baseline -> timer:sleep(case TimerMode of production -> 61000; accelerated -> 1500 end)
    end,
    IdleUs = now_us() - IdleStarted,
    After = census(P),
    case Version of
        candidate -> {pool_census, 4, 0, 0, 0, 0, 0, 4, 4} = After;
        baseline -> {pool_census, 4, 4, 0, 0, 0, 0, 4, 0} = After
    end,
    RssAfter = [{Pid, rss_kib(Pid)} || Pid <- Pids],
    AliveAfter = [Pid || Pid <- Pids, pid_exists(Pid)],
    case Version of candidate -> [] = AliveAfter; baseline -> 4 = length(AliveAfter) end,
    case Version of candidate -> true = lists:all(fun({_, R}) -> R =:= 0 end, RssAfter); _ -> ok end,
    BeamAfter = actor_memory(ActorPids),
    Started = now_us(),
    _ = command(P),
    ResumeUs = now_us() - Started,
    _ = census(P),
    io:format("IDLE version=~p timer=~p idle_us=~p rss_before_kib=~0p rss_after_kib=~0p actor_postgc_before_bytes=~p actor_postgc_after_bytes=~p resume_call_us=~p census=~0p alive_after=~0p~n",
              [Version, TimerMode, IdleUs, RssBefore, RssAfter, BeamBefore, BeamAfter, ResumeUs, After, AliveAfter]),
    close(P).

await_empty(P, Deadline) ->
    case census(P) of
        {pool_census, _, 0, 0, 0, 0, 0, 4, 4} -> ok;
        C ->
            case now_us() > Deadline of true -> error({retirement_deadline, C}); false -> ok end,
            timer:sleep(10), await_empty(P, Deadline)
    end.

%% Port OS identities restrict RSS queries to helpers this isolated VM owns.
%% Summed RSS can count shared pages more than once and is not physical RAM.
native_pids() ->
    [Pid || Port <- erlang:ports(), {os_pid, Pid} <- [erlang:port_info(Port, os_pid)], is_integer(Pid)].

pid_exists(Pid) ->
    string:trim(os:cmd("ps -o pid= -p " ++ integer_to_list(Pid))) =/= "".

rss_kib(Pid) ->
    Text = string:trim(os:cmd("ps -o rss= -p " ++ integer_to_list(Pid))),
    case Text of "" -> 0; _ -> list_to_integer(Text) end.

actor_memory(Pids) ->
    %% Collection is confined to this synthetic pool and its helper actors.
    [erlang:garbage_collect(Pid) || Pid <- Pids],
    lists:sum([case erlang:process_info(Pid, memory) of {memory, Bytes} -> Bytes; undefined -> 0 end
               || Pid <- Pids]).

actor_reductions(Pids) ->
    lists:sum([begin {reductions, Count} = erlang:process_info(Pid, reductions), Count end || Pid <- Pids]).

now_us() -> erlang:monotonic_time(microsecond).
