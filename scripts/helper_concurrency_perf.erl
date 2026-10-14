%% Real jailed workloads in one selected, already-built protocol stack.
%% A separate VM must be used for each root; native wire versions never mix.
-module(helper_concurrency_perf).
-export([main/0]).

main() ->
    [Root, Version0, Round0] = init:get_plain_arguments(),
    Version = list_to_existing_atom(Version0),
    Round = list_to_integer(Round0),
    {ok, _} = application:ensure_all_started(broker),
    io:format("META version=~p round=~p otp=~s schedulers=~p parallel_samples=15 root=~s~n",
              [Version, Round, erlang:system_info(otp_release),
               erlang:system_info(schedulers_online), Root]),
    lists:foreach(fun(Slots) -> fixture(Root, Version, Slots) end, [1, 4, 8]),
    halt(0).

fixture(Root, Version, Slots) ->
    P = open(Root, Slots),
    Before = native_pids(),
    ColdStart = now_us(),
    Helpers = leases(P, Slots),
    _ = batch(P, Helpers, <<"cold">>),
    ColdUs = now_us() - ColdStart,
    Native = native_pids() -- Before,
    Expected = case Version of baseline -> Slots; candidate -> (Slots + 3) div 4; preoptimization -> (Slots + 3) div 4 end,
    Expected = length(Native),
    Actors = lists:usort(['broker@exec':pool_pid(element(1, P)) |
                         ['broker@exec':pid(H) || H <- Helpers]]),
    io:format("COLD version=~p slots=~p native_count=~p actor_count=~p elapsed_us=~p~n",
              [Version, Slots, length(Native), length(Actors), ColdUs]),
    return_all(P, Helpers),
    lists:foreach(fun(_) -> cycle(P) end, lists:seq(1, 100)),
    lists:foreach(fun(Index) -> warm_cycles(P, Actors, Version, Slots, Index) end,
                  lists:seq(1, 7)),
    lists:foreach(fun(Index) ->
        H = checkout(P),
        Start = now_us(),
        _ = batch(P, [H], <<"sequential">>),
        Elapsed = now_us() - Start,
        checkin(P, H),
        io:format("CALL version=~p slots=~p sample=~p elapsed_us=~p~n",
                  [Version, Slots, Index, Elapsed])
    end, lists:seq(1, 35)),
    lists:foreach(fun(Index) ->
        Hs = leases(P, Slots),
        Start = now_us(),
        _ = batch(P, Hs, <<"parallel">>),
        Elapsed = now_us() - Start,
        return_all(P, Hs),
        io:format("PARALLEL version=~p slots=~p sample=~p elapsed_us=~p~n",
                  [Version, Slots, Index, Elapsed])
    end, lists:seq(1, 15)),
    memory(P, Version, Slots, Native, Actors),
    lists:foreach(fun(I) -> startup(P, Version, Slots, I) end, lists:seq(1, 5)),
    {ok, nil} = 'broker@exec':close_pool(element(1, P), 15000),
    'broker@exec':stop_pool(element(1, P)),
    await_dead(Native, now_us() + 5000000),
    io:format("CLOSED version=~p slots=~p native_survivors=0~n", [Version, Slots]).

open(Root, Slots) ->
    Dir = filename:join([Root, "packages/broker/build/helper-concurrency-perf",
                        integer_to_list(erlang:system_time(nanosecond)) ++ "-" ++
                        integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join([Dir, "work", "placeholder"])),
    BDir = unicode:characters_to_binary(Dir),
    Policy = {sandbox_policy, [<<BDir/binary, "/work">>], [<<"/">>], [], network_off,
              {limits, 30, 60, 536870912, 64, 8388608, 1048576},
              [<<"PATH">>], scratch_tmpfs, []},
    Config = {spawn_config, unicode:characters_to_binary(filename:join(Root, "packages/sandbox/loom-exec")),
              <<"/bin/sh">>, Policy, [], <<BDir/binary, "/tmp">>, 5000, 3000, 0},
    {ok, Pool} = 'broker@exec':start_pool(Slots, fun() -> 'broker@exec':prepare_helper(Config) end),
    {Pool, BDir}.

checkout({Pool, _}) -> {ok, H} = 'broker@exec':checkout(Pool, 15000), H.
checkin({Pool, _}, H) -> 'broker@exec':checkin(Pool, H).
leases(P, N) -> [checkout(P) || _ <- lists:seq(1, N)].
return_all(P, Hs) ->
    [checkin(P, H) || H <- Hs],
    {ok, _} = 'broker@exec':pool_census(element(1, P), 5000), ok.
cycle(P) -> H = checkout(P), checkin(P, H).

warm_cycles(P, Actors, Version, Slots, Index) ->
    {Cpu0, _} = erlang:statistics(runtime),
    R0 = reductions(Actors),
    Start = now_us(),
    [cycle(P) || _ <- lists:seq(1, 2000)],
    {ok, _} = 'broker@exec':pool_census(element(1, P), 5000),
    Elapsed = now_us() - Start,
    {Cpu1, _} = erlang:statistics(runtime),
    io:format("WARM version=~p slots=~p batch=~p n=2000 total_us=~p vm_cpu_ms=~p actor_reductions=~p~n",
              [Version, Slots, Index, Elapsed, Cpu1 - Cpu0, reductions(Actors) - R0]).

%% All commands are accepted before waiting on any subject. Distinct output
%% makes cross-execution routing errors observable rather than just timed.
batch(P, Hs, Label) ->
    Runs = [begin
        Token = <<Label/binary, "-", (integer_to_binary(I))/binary, "\n">>,
        Subject = start(P, H, <<"printf '", Token/binary, "'">>),
        {Subject, Token}
    end || {H, I} <- lists:zip(Hs, lists:seq(1, length(Hs)))],
    [finish(S, T, <<>>) || {S, T} <- Runs].

start({_, Dir}, H, Script) ->
    S = 'gleam@erlang@process':new_subject(),
    Request = {exec_request, [<<"/bin/sh">>, <<"-c">>, Script],
               [{<<"PATH">>, <<"/usr/bin:/bin">>}], <<Dir/binary, "/work">>, none,
               <<"isolated-concurrency-benchmark">>, best_effort},
    {ok, nil} = 'broker@exec':run(H, Request, S, 10000), S.

finish(S, Expected, Acc) ->
    case 'gleam@erlang@process':'receive'(S, 15000) of
        {ok, {output, _, Data, _, false}} -> finish(S, Expected, <<Acc/binary, Data/binary>>);
        {ok, {exited, R}} -> Expected = Acc, verify_exit(R), R;
        Other -> error({unexpected_execution_event, Other})
    end.

verify_exit(R) ->
    0 = element(2, R), false = element(11, R), false = element(12, R),
    Layers = element(8, R),
    case os:type() of
        {unix, darwin} -> true = lists:member(<<"seatbelt">>, Layers),
                          true = lists:member(<<"seatbelt-net">>, Layers);
        {unix, linux} -> true = lists:member(<<"bwrap">>, Layers)
    end.

%% The filesystem gate holds every payload alive at the same time. Starting
%% output from every distinct subject must arrive before release is created.
memory(P = {_, Dir}, Version, Slots, Native, Actors) ->
    Hs = leases(P, Slots),
    Gate = <<Dir/binary, "/work/release">>,
    Runs = [begin
        Token = <<"started-", (integer_to_binary(I))/binary, "\n">>,
        Script = <<"printf '", Token/binary, "'; while [ ! -f '", Gate/binary,
                   "' ]; do /bin/sleep 0.01; done; printf 'done-", (integer_to_binary(I))/binary, "\n'">>,
        {start(P, H, Script), Token, <<"done-", (integer_to_binary(I))/binary, "\n">>}
    end || {H, I} <- lists:zip(Hs, lists:seq(1, Slots))],
    [await_marker(S, Marker, <<>>) || {S, Marker, _} <- Runs],
    Rss = [{Pid, rss_kib(Pid)} || Pid <- Native],
    true = lists:all(fun({_, R}) -> R > 0 end, Rss),
    [erlang:garbage_collect(Pid) || Pid <- Actors],
    Memory = lists:sum([begin {memory, B} = process_info(Pid, memory), B end || Pid <- Actors]),
    io:format("MEMORY version=~p slots=~p native_count=~p native_rss_kib=~0p actor_count=~p actor_postgc_bytes=~p~n",
              [Version, Slots, length(Native), Rss, length(Actors), Memory]),
    ok = file:write_file(Gate, <<"release">>),
    Results = [finish(S, Done, <<>>) || {S, _, Done} <- Runs],
    io:format("ENFORCEMENT version=~p slots=~p degraded=~0p layers=~0p~n",
              [Version, Slots, [element(9, R) || R <- Results], [element(8, R) || R <- Results]]),
    return_all(P, Hs).

await_marker(S, Expected, Acc) ->
    case 'gleam@erlang@process':'receive'(S, 15000) of
        {ok, {output, _, Data, _, false}} ->
            New = <<Acc/binary, Data/binary>>,
            case New of Expected -> ok; _ -> true = byte_size(New) < byte_size(Expected),
                                           await_marker(S, Expected, New) end;
        Other -> error({payload_not_concurrent, Other})
    end.

%% Attribution is separate from the original short-command timings. Every
%% payload emits a unique marker, waits for all peers, and sleeps briefly.
%% The gate prevents marker and terminal output merging on a loaded host. Submission measures
%% synchronous broker acceptance; marker observation also includes queued work.
startup(P = {_, Dir}, Version, Slots, Sample) ->
    Gate = <<Dir/binary, "/work/startup-release-", (integer_to_binary(Sample))/binary>>,
    Hs = leases(P, Slots),
    Begin = now_us(),
    Runs = [begin
        Marker = <<"phase-", (integer_to_binary(I))/binary, "\n">>,
        Done = <<"done-", (integer_to_binary(I))/binary, "\n">>,
        Script = <<"printf '", Marker/binary, "'; while [ ! -f '", Gate/binary,
                   "' ]; do /bin/sleep 0.01; done; /bin/sleep 0.05; printf '", Done/binary, "'">>,
        {start(P, H, Script), Marker, Done}
    end || {H, I} <- lists:zip(Hs, lists:seq(1, Slots))],
    Submitted = now_us() - Begin,
    [await_marker(S, Marker, <<>>) || {S, Marker, _} <- Runs],
    Marked = now_us() - Begin,
    ok = file:write_file(Gate, <<"release">>),
    Results = [finish(S, Done, <<>>) || {S, _, Done} <- Runs],
    Finished = now_us() - Begin,
    io:format("STARTUP version=~p slots=~p sample=~p submit_us=~p all_markers_us=~p total_us=~p exec_wall_ms=~w~n",
              [Version, Slots, Sample, Submitted, Marked, Finished,
               [element(10, R) || R <- Results]]),
    return_all(P, Hs).

%% These identities come from this VM's ports. Payloads and driver are not
%% included in native helper RSS; RSS totals may double-count shared pages.
native_pids() ->
    [Pid || Port <- erlang:ports(), {os_pid, Pid} <- [erlang:port_info(Port, os_pid)], is_integer(Pid)].
rss_kib(Pid) ->
    case string:trim(os:cmd("ps -o rss= -p " ++ integer_to_list(Pid))) of
        "" -> 0; Text -> list_to_integer(Text)
    end.
pid_exists(Pid) ->
    string:trim(os:cmd("ps -o pid= -p " ++ integer_to_list(Pid))) =/= "".
await_dead(Pids, Deadline) ->
    case [P || P <- Pids, pid_exists(P)] of
        [] -> ok;
        Alive -> true = now_us() < Deadline, timer:sleep(10), await_dead(Alive, Deadline)
    end.
reductions(Pids) ->
    lists:sum([begin {reductions, N} = process_info(P, reductions), N end || P <- Pids]).
now_us() -> erlang:monotonic_time(microsecond).
