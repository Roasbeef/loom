%% Disposable workers isolate decoded-field lifetime from the benchmark driver.
%% Full GC occurs only in these synthetic workers, never in a running daemon.
-module(json_retention_perf).
-export([main/1]).
-include("provider@stream_ResponseMachine.hrl").
-include("provider@adapter@openai_Accumulator.hrl").

main(Args) ->
    try run(Args)
    catch Class:Reason -> io:format("FAILED ~p:~0p~n", [Class, Reason]), halt(1) end.

run([Label, Expectation]) ->
    io:format("VM label=~s otp=~s word_bytes=~p schedulers=~p~n", [Label,
        erlang:system_info(otp_release), erlang:system_info(wordsize),
        erlang:system_info(schedulers_online)]),
    lists:foreach(fun({Name, Count, Padding, Size, Ownership}) ->
        Parent = self(),
        {Pid, Monitor} = spawn_monitor(fun() ->
            Values = [document(N, Padding, Size, Ownership) || N <- lists:seq(1, Count)],
            check_backing(Expectation, Ownership, Values),
            hold(Parent, Values)
        end),
        receive
            {Pid, ready} -> ok;
            {'DOWN', Monitor, process, Pid, Reason} -> error({fixture_failed, Name, Reason})
        after 60000 -> error({fixture_timeout, Name}) end,
        Pid ! {measure, self()},
        receive {Pid, Metrics} -> io:format("RETENTION ~s ~s count=~p padding=~p field=~p metrics=~0p~n",
            [Label, Name, Count, Padding, Size, Metrics]) end,
        Pid ! release,
        receive {Pid, Released} -> io:format("RELEASED ~s ~s metrics=~0p~n", [Label, Name, Released]) end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok end
    end, [{"selected_64", 32, 1048576, 64, selected},
          {"selected_65", 32, 1048576, 65, selected},
          {"selected_96", 32, 1048576, 96, selected},
          {"selected_256", 32, 1048576, 256, selected},
          {"selected_257", 32, 1048576, 257, selected},
          {"selected_ratio_exact_below", 1, 662, 96, selected},
          {"selected_ratio_exact", 1, 663, 96, selected},
          {"selected_ratio_below", 32, 600, 96, selected},
          {"selected_ratio_above", 32, 1000, 96, selected},
          {"provider_small_event", 16, 0, 96, provider},
          {"provider_64", 16, 1048576, 64, provider},
          {"provider_65", 16, 1048576, 65, provider},
          {"provider_accumulator", 16, 1048576, 96, provider},
          {"provider_256", 16, 1048576, 256, provider},
          {"provider_257", 16, 1048576, 257, provider},
          {"whole_document", 32, 1048576, 96, whole},
          {"source_still_owned", 32, 1048576, 96, source}]),
    provider_cost(Label),
    copy_cost(Label),
    lists:foreach(fun(Size) ->
        Field = binary:copy(<<"k">>, Size),
        Value = {array, lists:duplicate(2048, {string, Field})},
        Input = 'core@json':to_string(Value),
        {ok, Value} = 'core@json':parse(Input),
        repeat(5, Input),
        {reductions, Before} = process_info(self(), reductions),
        {Us, _} = timer:tc(fun() -> repeat(50, Input) end),
        {reductions, After} = process_info(self(), reductions),
        io:format("COPY_COST ~s field=~p count=2048 input_bytes=~p repetitions=50 us=~p reductions=~p~n",
            [Label, Size, byte_size(Input), Us, After - Before])
    end, [64, 65, 96, 256, 257]),
    halt().

repeat(0, _) -> ok;
repeat(N, Input) -> 'core@json':parse(Input), repeat(N - 1, Input).

%% Timing excludes tracing, input construction and retained-owner GC probes.
provider_cost(Label) ->
    lists:foreach(fun(Padding) ->
        Id = binary:copy(<<"i">>, 96),
        Model = binary:copy(<<"m">>, 96),
        Input = 'core@json':to_string({object, [
            {<<"id">>, {string, Id}}, {<<"model">>, {string, Model}},
            {<<"ignored">>, {string, binary:copy(<<"x">>, Padding)}},
            {<<"choices">>, {array, []}}]}),
        Chunk = <<"data: ", Input/binary, "\n\n">>,
        Machine = 'provider@adapter@openai':response_machine(
            {resolved_model, <<"fixture">>, <<"fixture-model">>, thinking_off, 32000, 4096}, 0),
        Start = (Machine#response_machine.on_status)(Machine#response_machine.init, 200, []),
        Run = fun() -> (Machine#response_machine.on_chunk)(Start, Chunk) end,
        {Acc, []} = Run(),
        {some, Id} = Acc#accumulator.response_id,
        repeat_run(5, Run),
        {reductions, Before} = process_info(self(), reductions),
        {Us, _} = timer:tc(fun() -> repeat_run(50, Run) end),
        {reductions, After} = process_info(self(), reductions),
        io:format("PROVIDER_COST ~s padding=~p input_bytes=~p repetitions=50 us=~p reductions=~p~n",
            [Label, Padding, byte_size(Input), Us, After - Before])
    end, [0, 1048576]).

%% The primitive cost is measured separately from parsing or retention savings.
copy_cost(Label) ->
    Large = binary:copy(<<"x">>, 1048576),
    Field = binary:part(Large, 32, 96),
    lists:foreach(fun({Name, Run}) ->
        repeat_run(1000, Run),
        {Us, _} = timer:tc(fun() -> repeat_run(100000, Run) end),
        io:format("PRIMITIVE_COST ~s method=~s field=96 repetitions=100000 us=~p~n",
            [Label, Name, Us])
    end, [{"singleton", fun() -> 'gleam@string':concat([Field]) end},
          {"materialized", fun() -> 'gleam@string':concat([Field, <<>>]) end}]).

repeat_run(0, _) -> ok;
repeat_run(N, Run) -> Run(), repeat_run(N - 1, Run).

%% Each input has its own backing allocation, and the decoded value is checked.
document(N, Padding, Size, provider) ->
    Id = binary:copy(<<"i">>, Size),
    Model = binary:copy(<<"m">>, Size),
    Large = binary:copy(<<"x">>, Padding),
    Input = 'core@json':to_string({object, [
        {<<"id">>, {string, Id}}, {<<"model">>, {string, Model}},
        {<<"ignored">>, {string, Large}}, {<<"choices">>, {array, []}},
        {<<"fixture_sequence">>, {int, N}}]}),
    Machine = 'provider@adapter@openai':response_machine(
        {resolved_model, <<"fixture">>, <<"fixture-model">>, thinking_off, 32000, 4096}, 0),
    Start = (Machine#response_machine.on_status)(Machine#response_machine.init, 200, []),
    {Acc, []} = (Machine#response_machine.on_chunk)(Start, <<"data: ", Input/binary, "\n\n">>),
    {some, Kept} = Acc#accumulator.response_id,
    Id = Kept,
    {some, Model} = Acc#accumulator.response_model,
    {Kept, Acc};
document(N, Padding, Size, Ownership) ->
    Large = binary:copy(<<"x">>, Padding),
    Field = binary:copy(<<"k">>, Size),
    Input = 'core@json':to_string({array, [{int, N}, {string, Large}, {string, Field}]}),
    {ok, {array, [{int, N}, {string, Large}, {string, Field}]} = Value} = 'core@json':parse(Input),
    {array, [_, _, {string, Kept}]} = Value,
    case Ownership of
        selected -> {Kept, none};
        whole -> {Kept, Value};
        source -> {Kept, Input}
    end.

%% The provider identity must detach within the bounded policy. Whole
%% documents and explicit input owners are measured separately, not asserted free.
check_backing("provider", provider, Values) ->
    lists:foreach(fun({Field, Acc}) ->
        {some, Model} = Acc#accumulator.response_model,
        true = (binary:referenced_byte_size(Field) =:= binary:referenced_byte_size(Model)),
        Size = byte_size(Field),
        Backing = binary:referenced_byte_size(Field),
        case Size > 64 andalso Size =< 256 of
            true -> true = (Backing =:= Size orelse Backing < Size * 8);
            false -> ok
        end
    end, Values);
check_backing("observe", _, _) -> ok;
check_backing("provider", _, _) -> ok.

%% The tail call drops parser locals before GC; inspection never returns data.
hold(Parent, Values) ->
    Parent ! {self(), ready},
    receive {measure, Parent} ->
        erlang:garbage_collect(),
        Parent ! {self(), metrics(Values)},
        receive release -> released(Parent) end
    end.

released(Parent) ->
    erlang:garbage_collect(),
    Parent ! {self(), metrics([])}.

metrics(Values) ->
    {binary, Binaries} = process_info(self(), binary),
    Unique = maps:from_list([{Id, Size} || {Id, Size, _Refs} <- Binaries]),
    {memory, Memory} = process_info(self(), memory),
    #{binary_bytes => lists:sum(maps:values(Unique)),
      binary_count => map_size(Unique), process_bytes => Memory,
      selected_bytes => lists:sum([byte_size(Field) || {Field, _} <- Values]),
      selected_backing_bytes => lists:sum([binary:referenced_byte_size(Field) || {Field, _} <- Values])}.
