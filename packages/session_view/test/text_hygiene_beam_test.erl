%% These properties concern BEAM binary ownership and allocation paths, which
%% portable Gleam cannot observe. Production normalization remains portable.
-module(text_hygiene_beam_test).
-include_lib("eunit/include/eunit.hrl").

clean_text_skips_codepoint_list_test() ->
    Module = 'session_view@text_hygiene',
    {module, Module} = code:ensure_loaded(Module),
    {ok, Session} = tprof:start(#{type => call_memory}),
    try
        tprof:set_pattern(Session, Module, strip_terminal_sequences, 1),
        tprof:enable_trace(Session, self(), #{set_on_spawn => false}),
        Clean = unicode:characters_to_binary("plain wörd 漢字 👍 text\n"),
        ?assertEqual(Clean, Module:multiline(Clean)),
        tprof:pause(Session),
        {call_memory, CleanRows} = tprof:collect(Session),
        ?assertEqual(0, calls(CleanRows)),

        %% A positive control proves the trace observes the unchanged slow path.
        tprof:continue(Session),
        ?assertEqual(<<"red">>, Module:multiline(<<27, "[31mred", 27, "[0m">>)),
        tprof:pause(Session),
        {call_memory, DirtyRows} = tprof:collect(Session),
        ?assertEqual(1, calls(DirtyRows))
    after
        tprof:stop(Session)
    end.

clean_slice_does_not_retain_input_buffer_test() ->
    Large = binary:copy(<<"a">>, 1024 * 1024),
    Slice = binary:part(Large, 700, 200),
    ?assertEqual(byte_size(Large), binary:referenced_byte_size(Slice)),
    Output = 'session_view@text_hygiene':multiline(Slice),
    ?assertEqual(Slice, Output),
    ?assertEqual(byte_size(Output), binary:referenced_byte_size(Output)).

calls(Rows) ->
    lists:sum([Count || {_, strip_terminal_sequences, 1, Pids} <- Rows,
                       {Pid, Count, _} <- Pids, Pid =:= self()]).
