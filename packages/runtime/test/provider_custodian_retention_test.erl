%% The parked worker needs one preparation capability, not its compatibility
%% facade. This native EUnit fixture inspects the actual started worker without
%% adding an FFI bridge: Gleam's process API does not decode Pids from links.
%% Runtime prepare starts exactly one linked worker plus its public custodian;
%% subtracting the old links and that public owner must leave exactly one Pid.
%% Flattened words describe a process copy's reachable term, not resident bytes.
-module(provider_custodian_retention_test).
-include_lib("eunit/include/eunit.hrl").

parked_worker_drops_unused_request_facade_test() ->
    Small = parked_words(0),
    Large = parked_words(4096),
    io:format("parked provider flattened words: ordinary=~p padded=~p~n",
              [Small, Large]),
    ?assertEqual(Small, Large).

prepared_begin_still_uses_the_admitted_preparation_test() ->
    {Surface, Spec, Token} = fixture(4096),
    {prepared, Handle, Begin} =
        'runtime@internal@provider_custodian':prepare(Surface, Spec),
    Witness = 'provider@stream':watch_drain(Handle),
    assert_not_prepared(Token),
    nil = Begin(),
    receive {prepared, Token, Spec} -> ok
    after 1000 -> error(preparation_not_admitted)
    end,
    ?assertMatch({ok, {[], {failed, {transport_failed, <<"fixture terminal">>}, _}}},
                 'provider@stream':await_terminal(Handle, 1000)),
    ?assertEqual(drained, 'provider@stream':await_drain(Witness, 1000)),
    assert_not_prepared(Token),
    assert_no_compatibility(Token).

parked_words(Padding) ->
    {Surface, Spec, Token} = fixture(Padding),
    {links, Before} = process_info(self(), links),
    {prepared, Handle, _Begin} =
        'runtime@internal@provider_custodian':prepare(Surface, Spec),
    {stream_handle, _, _, {some, Owner}} = Handle,
    {links, After} = process_info(self(), links),
    [Worker] = (After -- Before) -- [Owner],
    Watch = monitor(process, Worker),
    Words = erts_debug:flat_size(sys:get_state(Worker, 1000)),
    assert_not_prepared(Token),
    Witness = 'provider@stream':watch_drain(Handle),
    nil = 'provider@stream':cancel(Handle),
    ?assertEqual(drained, 'provider@stream':await_drain(Witness, 1000)),
    receive {'DOWN', Watch, process, Worker, normal} -> ok
    after 1000 -> error(parked_worker_did_not_retire)
    end,
    assert_not_prepared(Token),
    assert_no_compatibility(Token),
    Words.

fixture(Padding) ->
    Caller = self(),
    Token = make_ref(),
    Marker = lists:seq(1, Padding),
    Request = fun(_) ->
        Caller ! {compatibility, Token, length(Marker)},
        error(unused_compatibility_facade)
    end,
    Prepare = fun(Spec) ->
        Caller ! {prepared, Token, Spec},
        Events = 'gleam@erlang@process':new_subject(),
        Handle = 'provider@stream':immediate(Events, fun() -> nil end),
        Begin = fun() ->
            'gleam@erlang@process':send(Events,
                {failed, {transport_failed, <<"fixture terminal">>},
                 'core@accounting':empty()})
        end,
        {prepared_stream, Handle, Begin}
    end,
    Generator = 'core@ids':generator('core@clock':fixed(1000), 1),
    {Operation, Next} = 'core@ids':mint_op(Generator),
    {Response, _} = 'core@ids':mint_entry(Next),
    Spec = {generation_request, Operation, <<"fixture-step">>, 1, Response,
            'support@harness':configuration(), [], {object, []}},
    {{prepared_provider_surface, Request, Prepare, 1000}, Spec, Token}.

assert_not_prepared(Token) ->
    receive {prepared, Token, _} -> error(unexpected_preparation)
    after 0 -> ok
    end.

assert_no_compatibility(Token) ->
    receive {compatibility, Token, _} -> error(compatibility_facade_was_called)
    after 0 -> ok
    end.
