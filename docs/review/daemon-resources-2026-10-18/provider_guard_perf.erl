%% Synthetic provider requests only. No daemon or real provider is contacted.
-module(provider_guard_perf).
-export([main/0]).

main() ->
    {ok, _} = application:ensure_all_started(provider),
    lists:foreach(fun(Count) -> run(Count) end, [100, 10000]),
    halt().

run(Count) ->
    Parent = self(),
    Transport = {transport, fun(Request, _Events) ->
        Native = spawn(fun() -> receive cancel -> ok end end),
        Parent ! {transport, self(), Native, byte_size(element(5, Request))},
        {ok, {prepared_request, {running_request, Native,
            fun() -> Native ! cancel, nil end}, fun() -> nil end}}
    end},
    Clock = 'core@clock':fixed(1700000000000),
    Secret = 'provider@secret':from_function(fun(_) -> {ok, <<"synthetic-key">>} end),
    Gw0 = 'provider@gateway':new(Transport, Secret, Clock),
    Gw = 'provider@gateway':add_provider(Gw0,
        {anthropic_provider, <<"fixture">>, <<"https://fixture.invalid">>, <<"key">>}),
    Target = {resolved_model, <<"fixture">>, <<"fixture">>, thinking_off, 200000, 8192},
    Messages = [{user_message, [{user_text, integer_to_binary(N), none}], N, none}
        || N <- lists:seq(1, Count)],
    Request = {provider_request, {for_resolved, Target}, none, Messages, [], none},
    Before = processes(),
    {prepared_stream, Handle = {stream_handle, _, Cancel, {some, Scope}}, Begin} =
        'provider@gateway':prepare(Gw, Request),
    [Guard] = [P || P <- processes() -- Before,
        element(1, proc_lib:translate_initial_call(P)) =:= 'weft@state_machine'],
    ParkedWords = erts_debug:flat_size(sys:get_state(Guard, 1000)),
    Monitor = monitor(process, Scope),
    {reductions, R0} = process_info(self(), reductions),
    {Us, _} = timer:tc(fun() ->
        Begin(),
        receive {transport, Pump, Native, BodyBytes} ->
            true = erlang:garbage_collect(Guard),
            true = erlang:garbage_collect(Pump),
            Words = erts_debug:flat_size(sys:get_state(Guard, 1000)),
            {memory, GuardBytes} = process_info(Guard, memory),
            {memory, PumpBytes} = process_info(Pump, memory),
            {reductions, R1} = process_info(self(), reductions),
            io:format("GUARD count=~p parked_words=~p active_words=~p guard_bytes=~p pump_bytes=~p body_bytes=~p driver_reductions=~p native_alive=~p~n",
                [Count, ParkedWords, Words, GuardBytes, PumpBytes, BodyBytes,
                 R1-R0, is_process_alive(Native)])
        after 30000 -> error(transport_timeout) end
    end),
    Cancel(),
    receive {'DOWN', Monitor, process, Scope, normal} -> ok
    after 10000 -> error({drain_timeout, Handle}) end,
    io:format("DONE count=~p observed_us=~p~n", [Count, Us]).
