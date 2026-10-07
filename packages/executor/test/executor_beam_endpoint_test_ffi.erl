%% This test-only probe injects a captured private local handoff, never network
%% enrollment or a production RPC callback. Exact state tags fail on layout drift.
-module(executor_beam_endpoint_test_ffi).
-export([credits/1, capture/1, head/1, inject_idle/2, inject_active/2,
         capture_release/1, inject_release/2, retire_idle/1, retire_busy/1,
         answer_waiting/1, joined_waiting/1]).

credits(Server) ->
    {state, _, Records, _} = sys:get_state(Server),
    [Subject || {credit_record, data, Subject, _, available} <- Records].

capture(Subjects) ->
    {ok, [capture_credit(Subject) || Subject <- Subjects]}.

capture_credit({subject, Pid, _} = Subject) ->
    State = sys:get_state(Pid),
    credit = element(1, State),
    RequestDoor = element(6, State),
    {native_hello, Envelope, Reply} = element(14, State),
    {some, Correlation} = element(16, State),
    {Subject, RequestDoor, Correlation, {native_request, Envelope, Reply}}.

head(Server) ->
    [Subject | _] = credits(Server),
    Subject.

inject_idle(Probe, Subject) ->
    try
        {_, Door, Old, Request} = matching(Probe, Subject),
        {subject, Pid, _} = Subject,
        Before = sys:get_state(Pid),
        none = element(16, Before),
        no_ask = element(14, Before),
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
        {some, Current} = element(16, Before),
        true = Current =/= Old,
        {native_hello, _, _} = element(14, Before),
        send(Door, {Old, Request}),
        _ = erlang:process_info(Pid, current_function),
        After = sys:get_state(Pid),
        true = Before =:= After,
        {ok, nil}
    catch _:_ -> {error, nil} end.

matching(Probe, Subject) ->
    hd([Entry || {Saved, _, _, _} = Entry <- Probe, Saved =:= Subject]).
send({subject, Pid, Tag}, Value) -> Pid ! {Tag, Value}, ok.

%% These probes observe concrete managed-task custody and inject only the captured
%% original controller release. They cannot manufacture an answer or join witness.
capture_release(Server) ->
    {state, _, Records, _} = sys:get_state(Server),
    [{Subject, Original} | _] =
        [{Subject, Original} ||
            {credit_record, data, Subject, _, {assigned, Original}} <- Records],
    {Subject, Original}.

inject_release({Subject, Original}, {server, Door, Server}) ->
    send(Door, {released, Subject, Original}),
    _ = sys:get_state(Server),
    {ok, nil}.

retire_idle(Server) ->
    {state, _, Records, _} = sys:get_state(Server),
    [Subject | _] =
        [Subject || {credit_record, data, Subject, _, available} <- Records],
    send(Subject, close_credit),
    nil.

retire_busy(Server) ->
    {state, _, Records, _} = sys:get_state(Server),
    [Subject | _] =
        [Subject || {credit_record, data, Subject, _, {assigned, _}} <- Records],
    send(Subject, close_credit),
    nil.

answer_waiting(Server) ->
    custody_matches(Server, fun(State) ->
        element(12, State) =/= none andalso element(14, State) =:= no_ask
    end).

joined_waiting(Server) ->
    custody_matches(Server, fun(State) ->
        element(12, State) =:= none andalso element(14, State) =/= no_ask
    end).

custody_matches(Server, Predicate) ->
    {state, _, Records, _} = sys:get_state(Server),
    lists:any(fun({credit_record, _, {subject, Pid, _}, _, {assigned, _}}) ->
                      Predicate(sys:get_state(Pid));
                 (_) -> false
              end, Records).
