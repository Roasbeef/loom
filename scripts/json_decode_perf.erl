%% Fixed decoding workloads with timing and root-only allocation tracing.
%% Only parse/1 is traced; its untraced callees are charged to that root.
%% Timed passes trace nothing, and results are checked before either pass.
%% Heap words exclude refcounted binary payloads, native memory and retention.
-module(json_decode_perf).
-export([main/1]).

main([Label, "equivalence"]) ->
    equivalence(Label);
main([Label, "benchmark"]) ->
    io:format("VM otp=~s word_bytes=~p schedulers=~p scope=parse/1~n",
        [erlang:system_info(otp_release), erlang:system_info(wordsize),
         erlang:system_info(schedulers_online)]),
    Plain = binary:copy(<<"A long ordinary payload line with words and identifiers. ">>, 2000),
    Escaped = binary:copy(<<"A line with \"quoted\" identifiers and a newline.\n">>, 2000),
    Dense = binary:copy(<<"\"\\\n\t">>, 12000),
    Short = {array, lists:flatten(lists:duplicate(512,
        [{string, <<>>}, {string, <<"path">>}, {string, <<"a\nb">>}, {string, <<"x">>}]))},
    Text = binary:copy(<<"tool output: \"quoted\" path /tmp/example\n">>, 64),
    Transcript = {object, [{<<"messages">>, {array, lists:duplicate(128,
        {object, [{<<"role">>, {string, <<"assistant">>}},
                  {<<"content">>, {string, Text}},
                  {<<"meta">>, {object, [{<<"empty">>, {string, <<>>}},
                                        {<<"count">>, {int, 7}}]}}]})}}]},
    lists:foreach(fun({Name, Value}) ->
        Input = 'core@json':to_string(Value),
        {ok, Value} = 'core@json':parse(Input),
        Run = fun() -> 'core@json':parse(Input) end,
        repeat(5, Run),
        {reductions, Before} = process_info(self(), reductions),
        {Us, _} = timer:tc(fun() -> repeat(50, Run) end),
        {reductions, After} = process_info(self(), reductions),
        {ok, Profiler} = tprof:start(#{type => call_memory, session => json_decode_perf}),
        try
            tprof:set_pattern(Profiler, 'core@json', parse, 1),
            tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
            repeat(50, Run),
            tprof:pause(Profiler),
            #{all := {_, Words, _}} = tprof:inspect(tprof:collect(Profiler),
                total, {measurement, descending}),
            io:format("~s ~s bytes=~p repetitions=50 reductions=~p words=~p us=~p~n",
                [Label, Name, byte_size(Input), After - Before, Words, Us])
        after
            tprof:stop(Profiler)
        end
    end, [{"plain", {string, Plain}}, {"escaped", {string, Escaped}},
          {"dense", {string, Dense}}, {"dense_double", {string, <<Dense/binary, Dense/binary>>}},
          {"short", Short}, {"transcript", Transcript}]),
    ownership(Label),
    halt().

%% Results are checked before measurement and discarded between repetitions.
repeat(0, _) -> ok;
repeat(N, Run) -> Run(), repeat(N - 1, Run).

%% A selected output must not acquire a new reference to a large input binary.
ownership(Label) ->
    Large = binary:copy(<<"x">>, 1048576),
    Small = binary:copy(<<"kept">>, 24),
    Input = 'core@json':to_string({array, [{string, Large}, {string, Small}]}),
    {ok, {array, [_, {string, Kept}]}} = 'core@json':parse(Input),
    io:format("OWNERSHIP ~s input_bytes=~p kept_bytes=~p backing_bytes=~p~n",
        [Label, byte_size(Input), byte_size(Kept), binary:referenced_byte_size(Kept)]).

%% Compare complete results and corruption reports for fixed mutations, not
%% just acceptance. The hash excludes the label and is stable across builds.
equivalence(Label) ->
    Unicode = unicode:characters_to_binary([16#65E5, 16#1F600, $e, 16#301]),
    Docs = [<<"\"\"">>, <<"\"\\n\\t\\\"\\\\\"">>,
        <<"\"", Unicode/binary, "\\nrun\\uD834\\uDD1E\"">>,
        <<"{\"\":\"\\n\\t\",\"items\":[1,true,null,\"text\"]}">>,
        <<"[\"", Unicode/binary, "\", {\"k\": 2.5e3}]">>],
    Inputs = lists:flatmap(fun(Input) ->
        Size = byte_size(Input),
        Prefixes = [binary:part(Input, 0, N) || N <- lists:seq(0, Size)],
        Mutated = [begin
            <<Before:N/binary, _, After/binary>> = Input,
            <<Before/binary, Byte, After/binary>>
        end || N <- lists:seq(0, Size - 1), Byte <- [0, 1, 34, 92, 127, 128, 255]],
        [Input | Prefixes ++ Mutated]
    end, Docs),
    Results = [try 'core@json':parse(Input)
               catch Class:Reason -> {exception, Class, Reason} end || Input <- Inputs],
    Exceptions = length([bad || {exception, _, _} <- Results]),
    Digest = binary:encode_hex(crypto:hash(sha256, term_to_binary(Results)), lowercase),
    io:format("EQUIVALENCE ~s inputs=~p exceptions=~p sha256=~s~n",
        [Label, length(Inputs), Exceptions, Digest]),
    halt().
