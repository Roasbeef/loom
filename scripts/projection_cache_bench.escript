#!/usr/bin/env escript
%%! +S 1:1
%% Measures the private cache-hit path in a disposable, non-distributed VM.
%% Usage: escript scripts/projection_cache_bench.escript packages/runtime/build/dev/erlang
%% Build the runtime test package first, so support@fake is available.
-mode(compile).

main([Build]) -> run(Build, report);
main([Build, "--expect-cached"]) -> run(Build, expect_cached);
main(_) ->
    erlang:error("Expected the runtime build/dev/erlang directory, optionally --expect-cached").

run(Build, Check) ->
    lists:foreach(fun code:add_patha/1, filelib:wildcard(filename:join([Build, "*", "ebin"]))),
    Path = filename:join([Build, "runtime", "_gleam_artefacts", "runtime@strand_runtime.abstr"]),
    {ok, Encoded} = file:read_file(Path),
    Forms = binary_to_term(Encoded),
    %% The compiler's abstract forms let this VM call private functions without
    %% modifying a build artifact or exporting anything in the production VM.
    {ok, Module, Beam, _Warnings} = compile:forms(Forms, [binary, export_all, return_errors, return_warnings]),
    {module, Module} = code:load_binary(Module, Path, Beam),
    [{type, _, tuple, Fields}] = [T || {attribute, _, type, {state, T, []}} <- Forms],
    21 = length(Fields),
    %% Refuse a changed State layout rather than timing a different private slot.
    {remote_type, _, [{atom, _, gleam@option}, {atom, _, option}, [_]]} = lists:nth(20, Fields),
    Empty = setelement(20, list_to_tuple([state | lists:duplicate(20, undefined)]), none),
    io:format("otp=~s erts=~s word_bytes=~p schedulers=~p~n",
        [erlang:system_info(otp_release), erlang:system_info(version),
         erlang:system_info(wordsize), erlang:system_info(schedulers_online)]),
    lists:foreach(fun(Shape) -> measure(Module, Empty, Shape, Check) end, [ordinary, compacted]).

measure(Module, Empty, Shape, Check) ->
    Entries = fixture(Shape),
    Leaf = element(2, hd(Entries)),
    {Expected, State} = Module:remember(Empty, Leaf, Entries),
    Expected = 'runtime@hooks':project_from_scan(Entries),
    {some, Cache} = element(20, State),
    Raw = {cached, Leaf, Entries},
    Word = erlang:system_info(wordsize),
    %% Same-process shared size and flat copy cost answer different questions.
    io:format("~p messages=~p raw_shared_bytes=~p cached_shared_bytes=~p cached_flat_bytes=~p~n",
        [Shape, length(element(2, Expected)), erts_debug:size(Raw) * Word,
         erts_debug:size(Cache) * Word, erts_debug:flat_size(Cache) * Word]),
    true = ({ok, {Expected, State}} =:= Module:project_for(State, {some, Leaf})),
    %% Construction is excluded: these repetitions measure only unchanged-leaf
    %% reads, the path observed repeatedly in the running driver.
    loop(Module, State, Leaf, 20),
    lists:foreach(fun(_) ->
        erlang:garbage_collect(),
        {reductions, Before} = process_info(self(), reductions),
        Start = erlang:monotonic_time(microsecond),
        loop(Module, State, Leaf, 500),
        Us = erlang:monotonic_time(microsecond) - Start,
        {reductions, After} = process_info(self(), reductions),
        Delta = After - Before,
        %% This optional regression check uses work rather than a timing limit.
        %% The old projection costs millions of reductions for this fixture.
        case Check of
            report -> ok;
            expect_cached when Delta < 10000 -> ok;
            expect_cached -> erlang:error({projection_recomputed, Shape, Delta})
        end,
        io:format("~p hits=500 elapsed_us=~p reductions=~p~n", [Shape, Us, Delta])
    end, lists:seq(1, 7)).

loop(_Module, _State, _Leaf, 0) -> ok;
loop(Module, State, Leaf, N) ->
    {ok, {_Projected, State}} = Module:project_for(State, {some, Leaf}),
    loop(Module, State, Leaf, N - 1).

fixture(Shape) ->
    %% Each exchange has an adjacent tool result, matching a settled transcript.
    Messages = lists:append([exchange(N) || N <- lists:seq(1, 300)]),
    case Shape of
        ordinary ->
            lists:reverse(entries(Messages, 1, none));
        compacted ->
            %% A copied checkpoint tail also carries origin and usage metadata.
            [{compaction_entry, <<"checkpoint">>, none, 1201, 0, <<"summary">>,
              Messages, 10000, false, none}]
    end.

exchange(N) ->
    Id = integer_to_binary(N),
    ['support@fake':user(<<"prompt ", Id/binary>>),
     'support@fake':tool_use(<<"checking">>, [{Id, <<"read">>}], 7),
     {tool_result_message, Id, <<"read">>, [{tool_result_text, <<"result">>, none}],
      none, none, none, false, 0},
     'support@fake':answer(<<"done">>, 9)].

entries([], _Seq, _Parent) -> [];
entries([Message | Rest], Seq, Parent) ->
    Id = integer_to_binary(Seq),
    [{message_entry, Id, Parent, Seq, 0, Message, false} |
     entries(Rest, Seq + 1, {some, Id})].
