%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([prepare_stream_request/4, begin_stream_request/5,
         cancel_stream_request/1, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).
-define(RECOVERY_PROBE_TIMEOUT, 25).
-define(RECOVERY_RETRY, 10).

%% os:getenv/1 returns false | string(); normalize to Gleam's
%% {ok, Binary} | {error, nil}.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Allocates the one native owner before any application, DNS, socket, or HTTP
%% work begins. Gleam publishes this pid to its custodian and only then sends
%% the begin permit. The owner is both the raw httpc receiver and the drain
%% acknowledgement, so there is no unowned receiver between those two facts.
prepare_stream_request(OnStatus, OnChunk, OnEnd, OnFailure) ->
    Parent = self(),
    spawn(fun() ->
        native_parked(Parent, OnStatus, OnChunk, OnEnd, OnFailure)
    end).

%% Grants the parked native owner permission to capture the current manager and
%% issue the request. Sending is deliberately asynchronous: cancellation can
%% queue behind the small synchronous startup section without losing the pid
%% which must remain alive until that startup either fails or becomes
%% cancellable.
begin_stream_request(Owner, Method, Url, Headers, Body) ->
    Owner ! {begin_request, Method, Url, Headers, Body},
    nil.

%% Requests cancellation without confusing that request with its drain
%% acknowledgement. Gleam monitors the owner pid when it must wait; sends to a
%% process which has already completed are harmless.
cancel_stream_request(Owner) ->
    Owner ! cancel,
    nil.

native_parked(Parent, OnStatus, OnChunk, OnEnd, OnFailure) ->
    ParentMonitor = erlang:monitor(process, Parent),
    receive
        {begin_request, Method, Url, Headers, Body} ->
            start_native_request(Method, Url, Headers, Body, ParentMonitor,
                                 OnStatus, OnChunk, OnEnd, OnFailure);
        cancel ->
            ok;
        {'DOWN', ParentMonitor, process, Parent, _Reason} ->
            ok
    end.

start_native_request(Method, Url, Headers, Body, ParentMonitor,
                     OnStatus, OnChunk, OnEnd, OnFailure) ->
    Deadline = request_deadline(),
    case prepare_native_request(Method, Url, Headers, Body) of
        {ok, Manager, HandlerSupervisor, Request, Options} ->
            case admit_native_request(Method, Request, Options) of
                {ok, RequestId} ->
                    enter_native_loop(RequestId, Manager, ParentMonitor,
                                      OnStatus, OnChunk, OnEnd, OnFailure,
                                      none, false, Deadline);
                {error, _Reason} ->
                    start_failed(Manager, HandlerSupervisor, ParentMonitor,
                                 OnStatus, OnChunk, OnEnd, OnFailure,
                                 Deadline);
                interrupted ->
                    start_failed(Manager, HandlerSupervisor, ParentMonitor,
                                 OnStatus, OnChunk, OnEnd, OnFailure,
                                 Deadline)
            end;
        error ->
            safe_callback(OnFailure, [<<"http request startup failed">>])
    end.

%% Only startup and public admission are exception-normalized. Once httpc has
%% admitted a request, an unexpected fault must terminate this owner
%% abnormally; translating it into an ordinary provider error would falsely
%% certify that the native request had drained.
prepare_native_request(Method, Url, Headers, Body) ->
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        Manager = whereis(httpc_manager),
        HandlerSupervisor = whereis(httpc_handler_sup),
        HeaderList =
            [{unicode:characters_to_list(K), unicode:characters_to_list(V)}
             || {K, V} <- Headers],
        UrlList = unicode:characters_to_list(Url),
        Request =
            case Method of
                <<"GET">> -> {UrlList, HeaderList};
                _ -> {UrlList, HeaderList, content_type(HeaderList), Body}
            end,
        %% OTP 29 consumes max_connections_open in httpc_manager before the
        %% remaining options reach the socket. Unlimited admission prevents a
        %% request from waiting without a published handler, while nodelay
        %% keeps the non-empty list's dedicated, non-reused handler behavior.
        Receiver = response_receiver(self()),
        Options = [{sync, false}, {stream, self}, {body_format, binary},
                   {receiver, Receiver},
                   {socket_opts, [{max_connections_open, infinity},
                                  {nodelay, true}]}],
        {ok, Manager, HandlerSupervisor, Request, Options}
    catch
        _:_ -> error
    end.

admit_native_request(Method, Request, Options) ->
    try httpc:request(method_atom(Method), Request,
                      migration_safe_http_options(), Options)
    catch
        _:_ -> interrupted
    end.

%% A failed public call is conclusive only while the manager and handler
%% supervisor generations which received it remain alive. If either changed,
%% the manager may have admitted a handler before losing its reply. This owner
%% must then stay as the witness until that handler identifies itself through a
%% raw response; exiting here would turn an ambiguous admission into false
%% drain.
start_failed(Manager, HandlerSupervisor, ParentMonitor,
             OnStatus, OnChunk, OnEnd, OnFailure, Deadline) ->
    case same_generation(httpc_manager, Manager) andalso
         same_generation(httpc_handler_sup, HandlerSupervisor) of
        true ->
            safe_callback(OnFailure, [<<"http request startup failed">>]);
        false ->
            ambiguous_native_loop(Manager, ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure, false, Deadline)
    end.

same_generation(Name, Pid) when is_pid(Pid) ->
    whereis(Name) =:= Pid andalso is_process_alive(Pid);
same_generation(_Name, _Pid) ->
    false.

ambiguous_native_loop(Manager, ParentMonitor, OnStatus, OnChunk, OnEnd,
                      OnFailure, Stopping, Deadline) ->
    receive
        {http, Producer, Ack, {RequestId, _} = Message} ->
            enter_native_loop(RequestId, Manager, ParentMonitor, OnStatus,
                              OnChunk, OnEnd, OnFailure,
                              {Producer, Ack, Message}, Stopping, Deadline);
        {http, Producer, Ack, {RequestId, _, _} = Message} ->
            enter_native_loop(RequestId, Manager, ParentMonitor, OnStatus,
                              OnChunk, OnEnd, OnFailure,
                              {Producer, Ack, Message}, Stopping, Deadline);
        {http, Producer, Ack, {RequestId, _, _, _} = Message} ->
            enter_native_loop(RequestId, Manager, ParentMonitor, OnStatus,
                              OnChunk, OnEnd, OnFailure,
                              {Producer, Ack, Message}, Stopping, Deadline);
        cancel ->
            ambiguous_native_loop(Manager, ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure, true, Deadline);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            ambiguous_native_loop(Manager, ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure, true, Deadline)
    after remaining_ms(Deadline) ->
        case Stopping of
            true -> ok;
            false -> safe_callback(OnFailure,
                                   [<<"timed out waiting for the http response">>])
        end,
        %% No request identity ever arrived within the request's own deadline.
        %% That is not positive drain evidence, so fail the owner abnormally;
        %% the typed custodians above will poison recovery instead of retaining
        %% a witness with no remaining way to make progress.
        erlang:exit(self(), kill)
    end.

%% The callback handshake keeps the handler inside httpc_response:send/2 until
%% this owner has installed its monitor. That closes the fast-terminal race:
%% request_done cannot delete the manager row before capture acknowledges the
%% first response. The protected table remains the constant-time normal path.
enter_native_loop(RequestId, Manager, ParentMonitor, OnStatus, OnChunk, OnEnd,
                  OnFailure, FirstDelivery, Stopping, Deadline) ->
    case indexed_request_handler(RequestId) of
        {ok, Handler} ->
            enter_with_handler(RequestId, Handler, ParentMonitor, OnStatus,
                               OnChunk, OnEnd, OnFailure, FirstDelivery,
                               Stopping, Deadline);
        lost ->
            recover_handler(RequestId, Manager, ParentMonitor, OnStatus,
                            OnChunk, OnEnd, OnFailure, FirstDelivery,
                            Stopping, Deadline)
    end.

enter_with_handler(RequestId, Handler, ParentMonitor, OnStatus, OnChunk,
                   OnEnd, OnFailure, FirstDelivery, Stopping, Deadline) ->
    HandlerMonitor = erlang:monitor(process, Handler),
    case FirstDelivery of
        none ->
            case Stopping of
                true -> finish_native(RequestId, Handler, HandlerMonitor);
                false -> native_loop(RequestId, Handler, HandlerMonitor,
                                     ParentMonitor, OnStatus, OnChunk,
                                     OnEnd, OnFailure, Deadline)
            end;
        {Producer, Ack, Message} ->
            accept_response(Producer, Ack),
            case Stopping of
                true -> finish_native(RequestId, Handler, HandlerMonitor);
                false -> native_http(Message, RequestId, Handler,
                                     HandlerMonitor, ParentMonitor, OnStatus,
                                     OnChunk, OnEnd, OnFailure, Deadline)
            end
    end.

%% A missing row has two meanings. If the original manager still owns its
%% table, the handler has already gone and any terminal callback is merely
%% queued. If the manager generation changed, the old handler can still own a
%% socket after its table vanished, so the rare path below recovers it exactly.
recover_handler(RequestId, Manager, ParentMonitor, OnStatus, OnChunk, OnEnd,
                OnFailure, FirstDelivery, Stopping, Deadline) ->
    case FirstDelivery of
        {Producer, Ack, Message} ->
            enter_with_handler(RequestId, Producer, ParentMonitor, OnStatus,
                               OnChunk, OnEnd, OnFailure,
                               {Producer, Ack, Message}, Stopping, Deadline);
        none ->
            receive
                {http, Producer, Ack, {RequestId, _} = Message} ->
                    enter_with_handler(RequestId, Producer, ParentMonitor,
                                       OnStatus, OnChunk, OnEnd, OnFailure,
                                       {Producer, Ack, Message}, Stopping,
                                       Deadline);
                {http, Producer, Ack, {RequestId, _, _} = Message} ->
                    enter_with_handler(RequestId, Producer, ParentMonitor,
                                       OnStatus, OnChunk, OnEnd, OnFailure,
                                       {Producer, Ack, Message}, Stopping,
                                       Deadline);
                {http, Producer, Ack, {RequestId, _, _, _} = Message} ->
                    enter_with_handler(RequestId, Producer, ParentMonitor,
                                       OnStatus, OnChunk, OnEnd, OnFailure,
                                       {Producer, Ack, Message}, Stopping,
                                       Deadline);
                cancel ->
                    conservative_cancel(RequestId),
                    recover_handler(RequestId, Manager, ParentMonitor,
                                    OnStatus, OnChunk, OnEnd, OnFailure, none,
                                    true, Deadline);
                {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
                    conservative_cancel(RequestId),
                    recover_handler(RequestId, Manager, ParentMonitor,
                                    OnStatus, OnChunk, OnEnd, OnFailure, none,
                                    true, Deadline)
            after 0 ->
                recover_after_empty_mailbox(
                  RequestId, Manager, ParentMonitor, OnStatus, OnChunk, OnEnd,
                  OnFailure, Stopping, Deadline)
            end
    end.

recover_after_empty_mailbox(RequestId, Manager, ParentMonitor, OnStatus,
                            OnChunk, OnEnd, OnFailure, Stopping, Deadline) ->
    case same_generation(httpc_manager, Manager) of
        true -> finish_gone(Stopping, OnFailure);
        false ->
            case discover_request_handler(RequestId) of
                {ok, Handler} ->
                    enter_with_handler(RequestId, Handler, ParentMonitor,
                                       OnStatus, OnChunk, OnEnd, OnFailure,
                                       none, Stopping, Deadline);
                gone -> finish_gone(Stopping, OnFailure);
                inconclusive ->
                    recovering_loop(RequestId, Manager, ParentMonitor,
                                    OnStatus, OnChunk, OnEnd, OnFailure,
                                    Stopping, Deadline)
            end
    end.

finish_gone(true, _OnFailure) ->
    ok;
finish_gone(false, OnFailure) ->
    %% The callback handshake prevents a live response producer from deleting
    %% its row before capture. No row under the original manager, or a complete
    %% recovery scan with no owner, therefore means there is nothing left to
    %% drain and the missing terminal can be reported in band.
    safe_callback(OnFailure, [<<"http transport failed">>]).

recovering_loop(RequestId, Manager, ParentMonitor, OnStatus, OnChunk, OnEnd,
                OnFailure, Stopping, Deadline) ->
    receive
        {http, Producer, Ack, {RequestId, _} = Message} ->
            enter_with_handler(RequestId, Producer, ParentMonitor, OnStatus,
                               OnChunk, OnEnd, OnFailure,
                               {Producer, Ack, Message}, Stopping, Deadline);
        {http, Producer, Ack, {RequestId, _, _} = Message} ->
            enter_with_handler(RequestId, Producer, ParentMonitor, OnStatus,
                               OnChunk, OnEnd, OnFailure,
                               {Producer, Ack, Message}, Stopping, Deadline);
        {http, Producer, Ack, {RequestId, _, _, _} = Message} ->
            enter_with_handler(RequestId, Producer, ParentMonitor, OnStatus,
                               OnChunk, OnEnd, OnFailure,
                               {Producer, Ack, Message}, Stopping, Deadline);
        cancel ->
            conservative_cancel(RequestId),
            recovering_loop(RequestId, Manager, ParentMonitor, OnStatus,
                            OnChunk, OnEnd, OnFailure, true, Deadline);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            conservative_cancel(RequestId),
            recovering_loop(RequestId, Manager, ParentMonitor, OnStatus,
                            OnChunk, OnEnd, OnFailure, true, Deadline)
    after ?RECOVERY_RETRY ->
        recover_after_empty_mailbox(RequestId, Manager, ParentMonitor,
                                    OnStatus, OnChunk, OnEnd, OnFailure,
                                    Stopping, Deadline)
    end.

native_loop(RequestId, Handler, HandlerMonitor, ParentMonitor,
            OnStatus, OnChunk, OnEnd, OnFailure, Deadline) ->
    receive
        {http, Producer, Ack, {RequestId, _} = Message} ->
            accept_response(Producer, Ack),
            native_http(Message, RequestId, Handler, HandlerMonitor,
                        ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure,
                        Deadline);
        {http, Producer, Ack, {RequestId, _, _} = Message} ->
            accept_response(Producer, Ack),
            native_http(Message, RequestId, Handler, HandlerMonitor,
                        ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure,
                        Deadline);
        {http, Producer, Ack, {RequestId, _, _, _} = Message} ->
            accept_response(Producer, Ack),
            native_http(Message, RequestId, Handler, HandlerMonitor,
                        ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure,
                        Deadline);
        cancel ->
            finish_native(RequestId, Handler, HandlerMonitor);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            finish_native(RequestId, Handler, HandlerMonitor);
        {'DOWN', HandlerMonitor, process, Handler, _Reason} ->
            safe_callback(OnFailure, [<<"http transport failed">>])
    after remaining_ms(Deadline) ->
        safe_callback(OnFailure, [<<"timed out waiting for the http response">>]),
        finish_native(RequestId, Handler, HandlerMonitor)
    end.

native_http({RequestId, stream_start, Headers}, RequestId, Handler,
            HandlerMonitor, ParentMonitor, OnStatus, OnChunk, OnEnd,
            OnFailure, Deadline) ->
    case safe_status_callback(OnStatus, 200, Headers) of
        ok -> native_loop(RequestId, Handler, HandlerMonitor, ParentMonitor,
                          OnStatus, OnChunk, OnEnd, OnFailure, Deadline);
        error -> finish_native(RequestId, Handler, HandlerMonitor)
    end;
native_http({RequestId, stream_start, Headers, _Handler}, RequestId, Handler,
            HandlerMonitor, ParentMonitor, OnStatus, OnChunk, OnEnd,
            OnFailure, Deadline) ->
    native_http({RequestId, stream_start, Headers}, RequestId, Handler,
                HandlerMonitor, ParentMonitor, OnStatus, OnChunk, OnEnd,
                OnFailure, Deadline);
native_http({RequestId, stream, Chunk}, RequestId, Handler, HandlerMonitor,
            ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure, Deadline) ->
    case safe_callback(OnChunk, [Chunk]) of
        ok -> native_loop(RequestId, Handler, HandlerMonitor, ParentMonitor,
                          OnStatus, OnChunk, OnEnd, OnFailure, Deadline);
        error -> finish_native(RequestId, Handler, HandlerMonitor)
    end;
native_http({RequestId, stream_end, _Headers}, RequestId, Handler,
            HandlerMonitor, _ParentMonitor, _OnStatus, _OnChunk, OnEnd,
            _OnFailure, _Deadline) ->
    safe_callback(OnEnd, []),
    finish_native(RequestId, Handler, HandlerMonitor);
native_http({RequestId, {error, _Reason}}, RequestId, Handler, HandlerMonitor,
            _ParentMonitor, _OnStatus, _OnChunk, _OnEnd, OnFailure,
            _Deadline) ->
    safe_callback(OnFailure, [<<"http transport failed">>]),
    finish_native(RequestId, Handler, HandlerMonitor);
native_http({RequestId, {{_Version, Status, _Reason}, Headers, Body}},
            RequestId, Handler, HandlerMonitor, _ParentMonitor, OnStatus,
            OnChunk, OnEnd, _OnFailure, _Deadline) ->
    case safe_status_callback(OnStatus, Status, Headers) of
        ok ->
            case safe_callback(OnChunk, [Body]) of
                ok -> safe_callback(OnEnd, []);
                error -> error
            end;
        error -> error
    end,
    finish_native(RequestId, Handler, HandlerMonitor).

indexed_request_handler(RequestId) ->
    %% The table name and row shape are an intentionally confined dependency
    %% on httpc_manager internals. OTP 29 creates this protected default-profile
    %% table and inserts {RequestId, HandlerPid, Receiver} before returning
    %% successful admission to the caller.
    try ets:lookup(httpc_manager__handler_db, RequestId) of
        [{RequestId, Handler, _Receiver}] when is_pid(Handler) -> {ok, Handler};
        _ -> lost
    catch
        error:badarg -> lost
    end.

discover_request_handler(RequestId) ->
    find_request_handler(RequestId, erlang:processes(), false).

find_request_handler(_RequestId, [], true) ->
    inconclusive;
find_request_handler(_RequestId, [], false) ->
    gone;
find_request_handler(RequestId, [Pid | Rest], Inconclusive) ->
    case is_httpc_handler(Pid) of
        false -> find_request_handler(RequestId, Rest, Inconclusive);
        true ->
            case bounded_handler_info(Pid) of
                {ok, Info} ->
                    case handler_owns_request(RequestId, Info) of
                        true -> {ok, Pid};
                        false -> find_request_handler(RequestId, Rest,
                                                      Inconclusive)
                    end;
                gone -> find_request_handler(RequestId, Rest, Inconclusive);
                inconclusive -> find_request_handler(RequestId, Rest, true)
            end
    end.

is_httpc_handler(Pid) ->
    case process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            lists:keyfind('$initial_call', 1, Dictionary) =:=
                {'$initial_call', {httpc_handler, init, 1}};
        undefined -> false
    end.

%% An orphaned handler may still be inside connect or response parsing instead
%% of its gen_server receive loop. One timed-out probe therefore makes the scan
%% inconclusive; it never licenses the owner to report drain.
bounded_handler_info(Pid) ->
    try gen_server:call(Pid, info, ?RECOVERY_PROBE_TIMEOUT) of
        Info when is_list(Info) -> {ok, Info};
        _Other -> inconclusive
    catch
        exit:{noproc, _} -> gone;
        exit:{normal, _} -> gone;
        exit:{shutdown, _} -> gone;
        _:_ -> inconclusive
    end.

%% OTP 29 nests the request identity under current_request. This decoder stays
%% deliberately exact so an unfamiliar handler layout cannot be mistaken for
%% ownership of the socket we need to drain.
handler_owns_request(RequestId, Info) ->
    Current = proplists:get_value(current_request, Info, []),
    lists:keyfind(id, 1, Current) =:= {id, RequestId}.

finish_native(RequestId, Handler, HandlerMonitor) ->
    %% Direct cancellation does not depend on whichever manager generation is
    %% registered now. Handler termination closes its socket before Down can
    %% reach this native owner.
    try httpc_handler:cancel(RequestId, Handler)
    catch
        _:_ -> ok
    end,
    await_process(HandlerMonitor, Handler).

await_process(Monitor, Pid) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok;
        {http, Pid, Ack, _Message} ->
            %% Cancellation can win while the handler is blocked delivering a
            %% response. Acknowledging and discarding it lets the queued cancel
            %% run, avoiding a callback/cancellation deadlock.
            accept_response(Pid, Ack),
            await_process(Monitor, Pid)
    end.

response_receiver(Owner) ->
    fun(Message) ->
        OwnerMonitor = erlang:monitor(process, Owner),
        Ack = make_ref(),
        Owner ! {http, self(), Ack, Message},
        receive
            {response_accepted, Ack} ->
                erlang:demonitor(OwnerMonitor, [flush]),
                ok;
            {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
                %% The callback runs inside httpc_handler. If its sole owner is
                %% gone, exiting here tears down the handler and its socket.
                exit(provider_owner_down)
        end
    end.

accept_response(Producer, Ack) ->
    Producer ! {response_accepted, Ack},
    ok.

conservative_cancel(RequestId) ->
    try httpc:cancel_request(RequestId)
    catch
        _:_ -> ok
    end.

safe_callback(Function, Arguments) ->
    try
        apply(Function, Arguments),
        ok
    catch
        _:_ -> error
    end.

safe_status_callback(Function, Status, Headers) ->
    try
        apply(Function, [Status, normalize_headers(Headers)]),
        ok
    catch
        _:_ -> error
    end.

request_deadline() ->
    erlang:monotonic_time(millisecond) + ?RESPONSE_TIMEOUT.

remaining_ms(Deadline) ->
    max(Deadline - erlang:monotonic_time(millisecond), 0).

%% Redirects and Retry-After retries retain the public request id while moving
%% work to a different handler. Disable both migrations so the captured handler
%% remains authoritative. OTP 29's inets accepts autoretry directly; keeping
%% the fixed option list makes the lifecycle policy visible at the call site.
migration_safe_http_options() ->
    [{autoretry, 0},
     {timeout, ?RESPONSE_TIMEOUT},
     {connect_timeout, 30000},
     {autoredirect, false}].

content_type(HeaderList) ->
    case lists:keyfind("content-type", 1, [{string:lowercase(K), V} || {K, V} <- HeaderList]) of
        {_, Value} -> Value;
        false -> "application/json"
    end.

method_atom(<<"GET">>) -> get;
method_atom(<<"PUT">>) -> put;
method_atom(<<"DELETE">>) -> delete;
method_atom(_) -> post.

normalize_headers(Headers) ->
    [{unicode:characters_to_binary(string:lowercase(K)),
      unicode:characters_to_binary(V)}
     || {K, V} <- Headers].
