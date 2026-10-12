%% Compare a saved baseline BEAM with the built Gleam encoder in a fresh VM.
%% Renaming the baseline module leaves its function bodies unchanged. Timing
%% traces nothing; root-only call_memory tracing measures cumulative heap words
%% separately, excluding refcounted payloads, native allocations and retention.
-module(json_encode_perf).
-export([main/1]).

main([Baseline]) ->
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Baseline, [abstract_code]),
    Renamed = [case Form of
        {attribute, Line, module, _} -> {attribute, Line, module, json_encode_baseline};
        Other -> Other
    end || Form <- Forms],
    {ok, json_encode_baseline, Binary} = compile:forms(Renamed, [binary]),
    {module, json_encode_baseline} = code:load_binary(json_encode_baseline, "baseline", Binary),
    io:format("VM otp=~s word_bytes=~p schedulers=~p~n", [erlang:system_info(otp_release),
        erlang:system_info(wordsize), erlang:system_info(schedulers_online)]),
    Fixtures = [{"transcript16", transcript(16)}, {"transcript128", transcript(128)},
        {"transcript1024", transcript(1024)},
        {"wide_array", {array, lists:duplicate(10000, {int, 7})}},
        {"wide_object", {object, [{integer_to_binary(I), {int, I}} || I <- lists:seq(1,10000)]}},
        {"empty", {object, []}}, {"scalar", {string, <<"unchanged scalar">>}}],
    equivalence(Fixtures),
    lists:foreach(fun({Name, Value}) ->
        Bytes = byte_size('core@json':to_string(Value)),
        lists:foreach(fun(Round) ->
            Order = case Round rem 2 of 1 -> [json_encode_baseline, 'core@json'];
                0 -> ['core@json', json_encode_baseline] end,
            lists:foreach(fun(Module) -> timing(Name, Module, Value, Bytes, Round) end, Order)
        end, lists:seq(1, 8)),
        lists:foreach(fun(Module) -> allocation(Name, Module, Value, Bytes) end,
            [json_encode_baseline, 'core@json'])
    end, Fixtures),
    halt(0).

transcript(N) ->
    {array, [{object, [{<<"role">>, {string, <<"user">>}},
        {<<"content">>, {string, <<"text with a quote \" and a newline\n", 240,159,152,128>>}},
        {<<"sequence">>, {int, I}},
        {<<"nested">>, {array, [null, {bool, true}, {float, 1.25}]}}]}
        || I <- lists:seq(1, N)]}.

%% Include all C0 controls, quotes, slashes, multibyte and combining text in
%% keys and values; keep deliberately duplicated keys as a byte-only contract.
equivalence(Fixtures) ->
    Texts = [unicode:characters_to_binary([C, 16#e9, 16#4e2d, 16#1f600, $e, 16#301])
        || C <- lists:seq(0, 127)],
    Values = [V || {_, V} <- Fixtures] ++ [null, {bool, false}, {int, 1 bsl 100},
        {float, -0.0}, {float, 1.0e30}, {array, []},
        {object, [{<<"z">>, null}, {<<"z">>, {int, 2}}]}] ++
        [{object, [{T, {array, [{string, T}, {object, []}, {array, []}]}}]} || T <- Texts] ++
        [nested(N) || N <- lists:seq(1, 256)],
    Encoded = [begin
        Expected = json_encode_baseline:to_string(Value),
        Expected = 'core@json':to_string(Value),
        Expected
    end || Value <- Values],
    io:format("EQUIVALENCE values=~p sha256=~s~n", [length(Values),
        binary:encode_hex(crypto:hash(sha256, term_to_binary(Encoded)), lowercase)]).

nested(0) -> {string, <<"leaf">>};
nested(N) when N rem 2 =:= 0 -> {object, [{<<"key">>, nested(N - 1)}]};
nested(N) -> {array, [nested(N - 1)]}.

repeat(0, _) -> ok;
repeat(N, Run) -> _ = Run(), repeat(N - 1, Run).

timing(Name, Module, Value, Bytes, Round) ->
    Run = fun() -> Module:to_string(Value) end,
    repeat(10, Run),
    {reductions, Before} = process_info(self(), reductions),
    {Us, _} = timer:tc(fun() -> repeat(200, Run) end),
    {reductions, After} = process_info(self(), reductions),
    io:format("TIME ~s ~s round=~p bytes=~p repetitions=200 us=~p reductions=~p~n",
        [Name, Module, Round, Bytes, Us, After - Before]).

allocation(Name, Module, Value, Bytes) ->
    Run = fun() -> Module:to_string(Value) end,
    {ok, Profiler} = tprof:start(#{type => call_memory, session => json_encode_perf}),
    try
        tprof:set_pattern(Profiler, Module, to_string, 1),
        tprof:enable_trace(Profiler, self(), #{set_on_spawn => false}),
        repeat(100, Run),
        tprof:pause(Profiler),
        #{all := {_, Words, _}} = tprof:inspect(tprof:collect(Profiler), total,
            {measurement, descending}),
        io:format("ALLOC ~s ~s bytes=~p repetitions=100 words=~p~n",
            [Name, Module, Bytes, Words])
    after
        tprof:stop(Profiler)
    end.
