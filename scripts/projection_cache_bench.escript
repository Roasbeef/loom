#!/usr/bin/env escript
%%! +S 1:1
%% Measures the private cache-hit path in a disposable, non-distributed VM.
%% Usage: escript scripts/projection_cache_bench.escript packages/runtime/build/dev/erlang [--expect-cached]
%% Build the runtime test package first, so support@fake is available.
-mode(compile).

main([Build]) -> run(Build, report);
main([Build, "--expect-cached"]) -> run(Build, expect_cached);
main(_) ->
    erlang:error("Expected the runtime build/dev/erlang directory, optionally --expect-cached").

run(Build, Check) ->
    lists:foreach(fun code:add_patha/1, filelib:wildcard(filename:join([Build, "*", "ebin"]))),
    Path = filename:join([Build, "runtime", "_gleam_artefacts", "runtime@strand_runtime.abstr"]),
    Forms = generated_forms(Build, Path),
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
    lists:foreach(fun(Shape) -> measure(Module, Empty, Shape, Check) end, [ordinary, compacted]),
    provider_capture(Module, Forms, Empty, Check).

generated_forms(Build, Path) ->
    case file:read_file(Path) of
        {ok, Encoded} -> binary_to_term(Encoded);
        {error, enoent} ->
            %% Gleam 1.18 emits Erlang source; newer native builds emit abstract
            %% forms. Both become the same compiler input in this isolated VM.
            Source = filename:rootname(Path) ++ ".erl",
            Includes = filelib:wildcard(filename:join([Build, "*", "include"])),
            {ok, Forms} = epp:parse_file(Source, Includes, []),
            Forms
    end.

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

provider_capture(Module, Forms, Empty, Check) ->
    %% Replace only this VM's private spawn boundary with a capture sink. The
    %% real spawn_provider still constructs its actual worker closure, but no
    %% provider request or effect adoption runs. Production artifacts stay intact.
    Stub = {function, 0, spawn_provider_effect, 3, [
        {clause, 0, [{var, 0, '_Reaper'}, {var, 0, '_Logger'}, {var, 0, 'Body'}], [], [
            {call, 0, {remote, 0, {atom, 0, erlang}, {atom, 0, put}},
                [{atom, 0, provider_body}, {var, 0, 'Body'}]},
            {tuple, 0, [{call, 0, {remote, 0, {atom, 0, erlang}, {atom, 0, self}}, []},
                {'fun', 0, {clauses, [{clause, 0, [], [], [{atom, 0, nil}]}]}}]}
        ]}
    ]},
    Probe = [case F of
        {function, _, spawn_provider_effect, 3, _} -> Stub;
        _ -> F
    end || F <- Forms],
    {ok, Module, Beam, _} = compile:forms(Probe, [binary, export_all, return_errors, return_warnings]),
    {module, Module} = code:load_binary(Module, "provider capture probe", Beam),
    Entries = fixture(ordinary),
    Leaf = element(2, hd(Entries)),
    {Projected, Cached} = Module:remember(Empty, Leaf, Entries),
    Context = element(2, Projected),
    Light = provider_state(Cached, []),
    Heavy = provider_state(Cached, lists:seq(1, 8192)),
    true = (erts_debug:flat_size(Heavy) > erts_debug:flat_size(Light) + 8192),
    LightWords = worker_words(Module, Light, Leaf, Context),
    HeavyWords = worker_words(Module, Heavy, Leaf, Context),
    io:format("provider_body light_flat_words=~p padded_flat_words=~p~n", [LightWords, HeavyWords]),
    case Check of
        report -> ok;
        expect_cached when LightWords =:= HeavyWords -> ok;
        expect_cached -> erlang:error({provider_captured_sibling_state, LightWords, HeavyWords})
    end.

provider_state(Cached, Padding) ->
    %% The replay slot keeps an unrelated, growing tool payload reachable in
    %% the driver. Its value is never needed by a provider dispatch.
    Tools = {tool_surface, fun(_) -> undefined end, fun(_) -> undefined end,
        fun(_) -> length(Padding) =:= 0 end, fun(_) -> concurrent_execution end},
    Surface = {provider_surface, fun(_) -> undefined end, 60000},
    Effects = {effects, undefined, undefined, undefined, Surface, Tools, undefined},
    S1 = setelement(2, Cached, 'gleam@erlang@process':new_subject()),
    S2 = setelement(5, S1, Effects),
    S3 = setelement(12, S2, 'telemetry@log':discard()),
    setelement(13, S3, {reaper, undefined, none, self()}).

worker_words(Module, State, Leaf, Context) ->
    {ok, Op} = 'core@ids':parse_op_id(<<"00000000-0000-7000-8000-000000000001">>),
    Token = {assistant_effect, Op, <<"step">>, Leaf},
    Configuration = 'support@harness':configuration(),
    Spec = {generation_request, Op, <<"step">>, 1, Leaf, Configuration, Context, {object, []}},
    _ = Module:spawn_provider(State, Token, Configuration, Spec),
    Body = erase(provider_body),
    true = is_function(Body, 1),
    erts_debug:flat_size(Body).
