%% Fixed decoding workloads with timing and root-only allocation tracing.
%% Only parse/1 is traced; its untraced callees are charged to that root.
%% Timed passes trace nothing, and results are checked before either pass.
%% Heap words exclude refcounted binary payloads, native memory and retention.
-module(json_decode_perf).
-export([main/1]).

main([Baseline, "compare"]) ->
    compare(Baseline);
main([Label, "equivalence"]) ->
    equivalence(Label);
main([Label, "benchmark"]) ->
    io:format("VM otp=~s word_bytes=~p schedulers=~p scope=parse/1~n",
        [erlang:system_info(otp_release), erlang:system_info(wordsize),
         erlang:system_info(schedulers_online)]),
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
    end, fixtures()),
    ownership(Label),
    halt().

fixtures() ->
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
    [{"plain", {string, Plain}}, {"escaped", {string, Escaped}},
     {"dense", {string, Dense}}, {"dense_double", {string, <<Dense/binary, Dense/binary>>}},
     {"short", Short}, {"transcript", Transcript}].

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

%% The comparison uses the encoder benchmark's existing baseline-renaming
%% pattern. Only the module attribute changes; both parsers run in one VM.
compare(Baseline) ->
    try
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
            beam_lib:chunks(Baseline, [abstract_code]),
        Renamed = [case Form of
            {attribute, Line, module, _} ->
                {attribute, Line, module, json_decode_baseline};
            Other -> Other
        end || Form <- Forms],
        {ok, json_decode_baseline, Binary} = compile:forms(Renamed, [binary]),
        {module, json_decode_baseline} =
            code:load_binary(json_decode_baseline, "baseline", Binary),
        io:format("VM otp=~s word_bytes=~p schedulers=~p scope=parse/1 baseline_sha256=~s~n",
            [erlang:system_info(otp_release), erlang:system_info(wordsize),
             erlang:system_info(schedulers_online),
             binary:encode_hex(crypto:hash(sha256, element(2, file:read_file(Baseline))), lowercase)]),
        compare_results(),
        Measurements = [compare_fixture(Name, Value) || {Name, Value} <- fixtures()],
        compare_ownership(),
        case os:getenv("JSON_DECODE_EXPECT_IMPROVED") of
            "yes" -> assert_improved(Measurements);
            _ -> ok
        end,
        halt(0)
    catch Class:Reason:Stack ->
        io:format("FAILED ~p:~p ~p~n", [Class, Reason, Stack]),
        halt(1)
    end.

compare_fixture(Name, Value) ->
    Input = 'core@json':to_string(Value),
    {ok, Value} = json_decode_baseline:parse(Input),
    {ok, Value} = 'core@json':parse(Input),
    lists:foreach(fun(Round) ->
        Order = case Round rem 2 of
            1 -> [json_decode_baseline, 'core@json'];
            0 -> ['core@json', json_decode_baseline]
        end,
        lists:foreach(fun(Module) -> compare_timing(Name, Module, Input, Round) end, Order)
    end, lists:seq(1, 8)),
    BaseWords = compare_allocation(Name, json_decode_baseline, Input),
    CandidateWords = compare_allocation(Name, 'core@json', Input),
    {Name, BaseWords, CandidateWords}.

compare_timing(Name, Module, Input, Round) ->
    Run = fun() -> Module:parse(Input) end,
    repeat(5, Run),
    {reductions, Before} = process_info(self(), reductions),
    {CpuBefore, _} = statistics(runtime),
    {Us, _} = timer:tc(fun() -> repeat(50, Run) end),
    {CpuAfter, _} = statistics(runtime),
    {reductions, After} = process_info(self(), reductions),
    io:format("TIME ~s ~s round=~p bytes=~p repetitions=50 us=~p reductions=~p cpu_ms=~p~n",
        [Name, Module, Round, byte_size(Input), Us, After - Before, CpuAfter - CpuBefore]).

compare_allocation(Name, Module, Input) ->
    {ok, Profiler} = tprof:start(#{type => call_memory, session => json_decode_compare}),
    try
        tprof:set_pattern(Profiler, Module, parse, 1),
        tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
        repeat(50, fun() -> Module:parse(Input) end),
        tprof:pause(Profiler),
        #{all := {_, Words, _}} = tprof:inspect(tprof:collect(Profiler), total,
            {measurement, descending}),
        io:format("ALLOC ~s ~s bytes=~p repetitions=50 words=~p~n",
            [Name, Module, byte_size(Input), Words]),
        Words
    after tprof:stop(Profiler) end.

%% Compare values AND complete corruption reports, including invalid UTF-8
%% injected below the String type, every truncation and delimiter positions.
compare_results() ->
    Unicode = unicode:characters_to_binary([16#e9, 16#4e2d, 16#1f600]),
    Docs = [<<"\"\"">>, <<"\"\\n\\t\\\"\\\\\"">>,
        <<"\"", Unicode/binary, "\\nrun\\uD834\\uDD1E\"">>,
        <<"{\"\":\"\\n\\t\",\"items\":[1,true,null,\"text\"]}">>,
        <<"{\"a\":0,\"\\u0061\":1}">>,
        <<"[\"", Unicode/binary, "\", {\"k\": 2.5e3}]">>] ++
        [begin
            Prefix = binary:copy(<<"x">>, N),
            <<" [\"previous\",{\"", Prefix/binary, Unicode/binary,
              "\\n\\u0041\\uD834\\uDD1E\":\"value\\tend\"}] ">>
        end || N <- lists:seq(0, 16)] ++
        [<<(binary:copy(<<"[">>, N))/binary, "0",
           (binary:copy(<<"]">>, N))/binary>> || N <- [255, 256, 257]],
    Mutated = lists:flatmap(fun(Input) ->
        Size = byte_size(Input),
        Prefixes = [binary:part(Input, 0, N) || N <- lists:seq(0, Size)],
        Changed = [begin
            <<Before:N/binary, _, After/binary>> = Input,
            <<Before/binary, Byte, After/binary>>
        end || N <- lists:seq(0, Size - 1), Byte <- [0, 1, 34, 92, 127, 128, 255]],
        [Input | Prefixes ++ Changed]
    end, Docs),
    EveryByte = [<<$", Byte, $">> || Byte <- lists:seq(0, 255)],
    Inputs = EveryByte ++ Mutated,
    Results = [begin
        Expected = json_decode_baseline:parse(Input),
        Actual = 'core@json':parse(Input),
        case Expected =:= Actual of
            true -> Expected;
            false -> error({parse_mismatch, byte_size(Input),
                crypto:hash(sha256, Input), Expected, Actual})
        end
    end || Input <- Inputs],
    io:format("EQUIVALENCE inputs=~p exceptions=0 sha256=~s~n", [length(Inputs),
        binary:encode_hex(crypto:hash(sha256, term_to_binary(Results)), lowercase)]).

%% Preserve the existing output-binary relationship, rather than confusing
%% cumulative heap allocation with improved reachable or resident memory.
compare_ownership() ->
    Large = binary:copy(<<"x">>, 1048576),
    Small = binary:copy(<<"kept">>, 24),
    Input = 'core@json':to_string({array, [{string, Large}, {string, Small}]}),
    {ok, {array, [_, {string, Base}]}} = json_decode_baseline:parse(Input),
    {ok, {array, [_, {string, Candidate}]}} = 'core@json':parse(Input),
    Base = Candidate,
    BaseBacking = binary:referenced_byte_size(Base),
    CandidateBacking = binary:referenced_byte_size(Candidate),
    true = CandidateBacking =< BaseBacking,
    io:format("OWNERSHIP input_bytes=~p kept_bytes=~p baseline_backing=~p candidate_backing=~p~n",
        [byte_size(Input), byte_size(Candidate), BaseBacking, CandidateBacking]).

%% Heap-word guards judge the optimization separately from noisy
%% timing. Supplying the unchanged BEAM as baseline must fail these guards.
assert_improved(Measurements) ->
    lists:foreach(fun({Name, Baseline, Candidate}) ->
        true = Candidate =< Baseline,
        case Name of
            "transcript" -> true = Candidate * 100 =< Baseline * 80;
            "dense" -> true = Candidate * 100 =< Baseline * 60;
            "dense_double" -> true = Candidate * 100 =< Baseline * 60;
            _ -> ok
        end
    end, Measurements),
    io:format("IMPROVEMENT allocation guards passed~n").
