%% This test-only probe injects a captured private local handoff, never network
%% enrollment or a production RPC callback. Exact state tags fail on layout drift.
-module(executor_beam_endpoint_test_ffi).
-export([credits/1, capture/1, head/1, inject_idle/2, inject_active/2]).

credits(Server) ->
    {state, _, Data, _, _} = sys:get_state(Server),
    Data.

capture(Subjects) ->
    {ok, [capture_credit(Subject) || Subject <- Subjects]}.

capture_credit({subject, Pid, _} = Subject) ->
    State = sys:get_state(Pid),
    credit = element(1, State),
    RequestDoor = element(6, State),
    {native_hello, Envelope, Reply} = element(13, State),
    {some, Correlation} = element(15, State),
    {Subject, RequestDoor, Correlation, {native_request, Envelope, Reply}}.

head(Server) ->
    [Subject | _] = credits(Server),
    Subject.

inject_idle(Probe, Subject) ->
    try
        {_, Door, Old, Request} = matching(Probe, Subject),
        {subject, Pid, _} = Subject,
        Before = sys:get_state(Pid),
        none = element(15, Before),
        no_ask = element(13, Before),
        send(Door, {Old, Request}),
        %% A same-sender sys barrier follows the injected handoff. No receive/0
        %% assumption is needed to establish that this test injection landed.
        _ = erlang:process_info(Pid, current_function),
        After = sys:get_state(Pid),
        true = Before =:= After,
        {ok, nil}
    catch _:_ -> {error, nil} end.

inject_active(Probe, Subject) ->
    try
        {_, Door, Old, Request} = matching(Probe, Subject),
        {subject, Pid, _} = Subject,
        Before = sys:get_state(Pid),
        {some, Current} = element(15, Before),
        true = Current =/= Old,
        {native_hello, _, _} = element(13, Before),
        send(Door, {Old, Request}),
        _ = erlang:process_info(Pid, current_function),
        After = sys:get_state(Pid),
        true = Before =:= After,
        {ok, nil}
    catch _:_ -> {error, nil} end.

matching(Probe, Subject) ->
    hd([Entry || {Saved, _, _, _} = Entry <- Probe, Saved =:= Subject]).
send({subject, Pid, Tag}, Value) -> Pid ! {Tag, Value}, ok.
