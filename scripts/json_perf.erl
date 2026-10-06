%% Bounded JSON codec fixture, run against one built checkout in a fresh VM.
%%
%% Use the same payloads and compiler/OTP builds on both sides of a comparison.
%% Alternate revisions: reductions and cumulative allocated words describe work;
%% wall time also reflects host load. No counter is live heap, native allocation
%% or RSS. These payloads exercise the codec alone; tui_perf measures its
%% contribution to a shipped update. Timed and traced passes are separate.
-module(json_perf).
-export([main/1]).

main([Label]) ->
    io:format("VM otp=~s word_bytes=~p schedulers=~p~n",
        [erlang:system_info(otp_release), erlang:system_info(wordsize),
         erlang:system_info(schedulers_online)]),
    Plain = binary:copy(
        <<"A long ordinary payload line with words and identifiers. ">>, 2000),
    Escaped = binary:copy(
        <<"A line with \"quoted\" identifiers and a newline.\n">>, 2000),
    lists:foreach(fun({Name, Value}) ->
        Encoded = 'core@json':to_string({string, Value}),
        {ok, {string, Value}} = 'core@json':parse(Encoded),
        Decode = fun() -> 'core@json':parse(Encoded) end,
        Encode = fun() -> 'core@json':to_string({string, Value}) end,
        lists:foreach(fun({Task, Run}) ->
            repeat(5, Run),
            {reductions, Before} = process_info(self(), reductions),
            {Us, _} = timer:tc(fun() -> repeat(50, Run) end),
            {reductions, After} = process_info(self(), reductions),
            {ok, Profiler} = tprof:start(#{type => call_memory, session => json_perf}),
            try
                tprof:set_pattern(Profiler, '_', '_', '_'),
                tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
                repeat(50, Run),
                tprof:pause(Profiler),
                Profile = tprof:inspect(tprof:collect(Profiler), total,
                    {measurement, descending}),
                #{all := {_, Words, _}} = Profile,
                io:format("~s ~s ~s bytes=~p repetitions=50 "
                          "reductions=~p words=~p us=~p~n",
                    [Label, Name, Task, byte_size(Value), After - Before, Words, Us])
            after
                tprof:stop(Profiler)
            end
        end, [{"encode", Encode}, {"decode", Decode}])
    end, [{"plain", Plain}, {"escaped", Escaped}]),
    halt().

%% Do not retain fifty results: the codec's work is what the fixture measures.
repeat(0, _) -> ok;
repeat(N, Run) ->
    Run(),
    repeat(N - 1, Run).
