%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([prepare_stream_request/4, begin_stream_request/5,
         cancel_stream_request/1, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).

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
    process_flag(trap_exit, true),
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
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        Manager = whereis(httpc_manager),
        true = is_pid(Manager),
        ManagerMonitor = erlang:monitor(process, Manager),
        start_managed_request(Manager, ManagerMonitor,
                              Method, Url, Headers, Body, ParentMonitor,
                              OnStatus, OnChunk, OnEnd, OnFailure)
    catch
        _Class:_CaughtReason ->
            safe_callback(OnFailure, [<<"http request startup failed">>])
    end.

%% Once the admitting manager generation is known, every failing branch drops
%% its monitor before reporting failure. Keeping that cleanup in a scope which
%% already owns the monitor prevents an exception during request construction
%% from fabricating a still-live manager witness.
start_managed_request(Manager, ManagerMonitor,
                      Method, Url, Headers, Body, ParentMonitor,
                      OnStatus, OnChunk, OnEnd, OnFailure) ->
    try
        HeaderList =
            [{unicode:characters_to_list(K), unicode:characters_to_list(V)}
             || {K, V} <- Headers],
        UrlList = unicode:characters_to_list(Url),
        Request =
            case Method of
                <<"GET">> -> {UrlList, HeaderList};
                _ -> {UrlList, HeaderList, content_type(HeaderList), Body}
            end,
        Options = [{sync, false}, {stream, self}, {body_format, binary},
                   {receiver, self()}, {socket_opts, [{nodelay, true}]}],
        case httpc:request(method_atom(Method), Request,
                           migration_safe_http_options(), Options) of
            {ok, RequestId} ->
                Handlers = request_handlers(RequestId),
                HandlerMonitors = monitor_processes(Handlers),
                native_loop(RequestId, Manager, ManagerMonitor,
                            HandlerMonitors, ParentMonitor,
                            OnStatus, OnChunk, OnEnd, OnFailure);
            {error, _Reason} ->
                erlang:demonitor(ManagerMonitor, [flush]),
                safe_callback(OnFailure, [<<"http request startup failed">>])
        end
    catch
        _Class:_CaughtReason ->
            erlang:demonitor(ManagerMonitor, [flush]),
            safe_callback(OnFailure, [<<"http request startup failed">>])
    end.

native_loop(RequestId, Manager, ManagerMonitor, HandlerMonitors, ParentMonitor,
            OnStatus, OnChunk, OnEnd, OnFailure) ->
    receive
        {http, {RequestId, stream_start, Headers}} ->
            case safe_callback(OnStatus, [200, normalize_headers(Headers)]) of
                ok ->
                    native_loop(RequestId, Manager, ManagerMonitor,
                                HandlerMonitors, ParentMonitor,
                                OnStatus, OnChunk, OnEnd, OnFailure);
                error ->
                    finish_native(RequestId, Manager, ManagerMonitor,
                                  HandlerMonitors)
            end;
        {http, {RequestId, stream, Chunk}} ->
            case safe_callback(OnChunk, [Chunk]) of
                ok ->
                    native_loop(RequestId, Manager, ManagerMonitor,
                                HandlerMonitors, ParentMonitor,
                                OnStatus, OnChunk, OnEnd, OnFailure);
                error ->
                    finish_native(RequestId, Manager, ManagerMonitor,
                                  HandlerMonitors)
            end;
        {http, {RequestId, stream_end, _Headers}} ->
            safe_callback(OnEnd, []),
            finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors);
        {http, {RequestId, {{_Version, Status, _Reason}, Headers,
                           ResponseBody}}} ->
            safe_callback(OnStatus, [Status, normalize_headers(Headers)]),
            safe_callback(OnChunk, [ResponseBody]),
            safe_callback(OnEnd, []),
            finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors);
        {http, {RequestId, {error, _Reason}}} ->
            safe_callback(OnFailure, [<<"http transport failed">>]),
            finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors);
        cancel ->
            finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors);
        {'DOWN', ManagerMonitor, process, Manager, _Reason} ->
            await_processes(HandlerMonitors),
            safe_callback(OnFailure, [<<"http transport failed">>]);
        {'DOWN', HandlerMonitor, process, _Handler, _Reason} ->
            Remaining = lists:keydelete(HandlerMonitor, 1, HandlerMonitors),
            finish_native(RequestId, Manager, ManagerMonitor, Remaining),
            safe_callback(OnFailure, [<<"http transport failed">>]);
        {'EXIT', Manager, _Reason} ->
            native_loop(RequestId, Manager, ManagerMonitor,
                        HandlerMonitors, ParentMonitor,
                        OnStatus, OnChunk, OnEnd, OnFailure)
    after ?RESPONSE_TIMEOUT ->
        finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors),
        safe_callback(OnFailure, [<<"timed out waiting for the http response">>])
    end.

%% The default manager inserts a fresh handler before replying with the request
%% id. A non-empty socket option disables connection reuse, so the matching pid
%% is this request's sole socket owner. If the manager disappears after the
%% reply, its monitor remains independent evidence and a captured handler is
%% still awaited rather than being forgotten with the manager's table.
request_handlers(RequestId) ->
    case httpc:info() of
        Info when is_list(Info) ->
            [Pid || {Pid, RequestIds, _Details} <-
                        proplists:get_value(handlers, Info, []),
                    lists:member(RequestId, RequestIds)];
        _ -> []
    end.

monitor_processes(Pids) ->
    [begin
         link(Pid),
         {erlang:monitor(process, Pid), Pid}
     end || Pid <- Pids].

finish_native(RequestId, Manager, ManagerMonitor, HandlerMonitors) ->
    try httpc:cancel_request(RequestId)
    catch
        _:_ -> ok
    end,
    await_processes(HandlerMonitors),
    erlang:demonitor(ManagerMonitor, [flush]),
    %% Keep the manager argument in the state transition: its monitor identifies
    %% the exact manager generation which admitted this request.
    _ = Manager,
    ok.

await_processes([]) ->
    ok;
await_processes([{Monitor, Pid} | Rest]) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> await_processes(Rest)
    end.

safe_callback(Function, Arguments) ->
    try
        apply(Function, Arguments),
        ok
    catch
        _:_ -> error
    end.

%% Redirects and Retry-After retries retain the public request id while moving
%% work to a different handler. Disable both migrations so the captured handler
%% remains authoritative. `autoretry` arrived in inets 9.6 (OTP 28.4); older
%% supported OTP releases reject the option and did not implement that retry.
migration_safe_http_options() ->
    Base = [{timeout, ?RESPONSE_TIMEOUT},
            {connect_timeout, 30000},
            {autoredirect, false}],
    case supports_autoretry_option() of
        true -> [{autoretry, 0} | Base];
        false -> Base
    end.

supports_autoretry_option() ->
    try application:get_key(inets, vsn) of
        {ok, Vsn} ->
            case [list_to_integer(N) || N <- string:tokens(Vsn, ".")] of
                [Major, Minor | _] -> Major > 9 orelse
                                      (Major =:= 9 andalso Minor >= 6);
                _ -> false
            end;
        _ -> false
    catch
        _:_ -> false
    end.

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
