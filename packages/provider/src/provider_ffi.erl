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
                enter_native_loop(RequestId, ParentMonitor,
                                  OnStatus, OnChunk, OnEnd, OnFailure);
            {error, _Reason} ->
                safe_callback(OnFailure, [<<"http request startup failed">>])
        end
    catch
        _Class:_CaughtReason ->
            safe_callback(OnFailure, [<<"http request startup failed">>])
    end.

%% The public manager table is not a lifetime witness: a manager restart loses
%% it while its separately supervised handler may still own a socket. The
%% handler supervisor is the stable side of that split. A successful request
%% reply happens only after the child is registered there, so a successful
%% scan either captures the exact request id or proves its handler terminated.
enter_native_loop(RequestId, ParentMonitor,
                  OnStatus, OnChunk, OnEnd, OnFailure) ->
    case request_handler(RequestId) of
        {ok, Handler} ->
            HandlerMonitor = erlang:monitor(process, Handler),
            native_loop(RequestId, Handler, HandlerMonitor, ParentMonitor,
                        OnStatus, OnChunk, OnEnd, OnFailure);
        gone ->
            %% A fast response may close after queuing its terminal and before
            %% discovery. No handler means no socket remains to acknowledge.
            native_loop(RequestId, undefined, undefined, ParentMonitor,
                        OnStatus, OnChunk, OnEnd, OnFailure);
        discovery_failed ->
            conservative_cancel(RequestId),
            await_discovery(RequestId),
            safe_callback(OnFailure, [<<"http transport failed">>])
    end.

native_loop(RequestId, Handler, HandlerMonitor, ParentMonitor,
            OnStatus, OnChunk, OnEnd, OnFailure) ->
    receive
        {http, {RequestId, stream_start, Headers}} ->
            case safe_callback(OnStatus, [200, normalize_headers(Headers)]) of
                ok -> native_loop(RequestId, Handler, HandlerMonitor,
                                  ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure);
                error -> finish_native(RequestId, Handler, HandlerMonitor)
            end;
        {http, {RequestId, stream, Chunk}} ->
            case safe_callback(OnChunk, [Chunk]) of
                ok -> native_loop(RequestId, Handler, HandlerMonitor,
                                  ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure);
                error -> finish_native(RequestId, Handler, HandlerMonitor)
            end;
        {http, {RequestId, stream_end, _Headers}} ->
            safe_callback(OnEnd, []),
            finish_native(RequestId, Handler, HandlerMonitor);
        {http, {RequestId, {{_Version, Status, _Reason}, Headers,
                           ResponseBody}}} ->
            safe_callback(OnStatus, [Status, normalize_headers(Headers)]),
            safe_callback(OnChunk, [ResponseBody]),
            safe_callback(OnEnd, []),
            finish_native(RequestId, Handler, HandlerMonitor);
        {http, {RequestId, {error, _Reason}}} ->
            safe_callback(OnFailure, [<<"http transport failed">>]),
            finish_native(RequestId, Handler, HandlerMonitor);
        cancel ->
            finish_native(RequestId, Handler, HandlerMonitor);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            finish_native(RequestId, Handler, HandlerMonitor);
        {'DOWN', HandlerMonitor, process, Handler, _Reason}
          when HandlerMonitor =/= undefined ->
            safe_callback(OnFailure, [<<"http transport failed">>])
    after ?RESPONSE_TIMEOUT ->
        finish_native(RequestId, Handler, HandlerMonitor),
        safe_callback(OnFailure, [<<"timed out waiting for the http response">>])
    end.

request_handler(RequestId) ->
    try supervisor:which_children(httpc_handler_sup) of
        Children when is_list(Children) ->
            find_request_handler(RequestId, Children)
    catch
        _:_ -> discovery_failed
    end.

find_request_handler(_RequestId, []) ->
    gone;
find_request_handler(RequestId, [{_Id, Pid, _Type, _Modules} | Rest])
  when is_pid(Pid) ->
    case handler_owns_request(RequestId, httpc_handler:info(Pid)) of
        true -> {ok, Pid};
        false -> find_request_handler(RequestId, Rest)
    end;
find_request_handler(RequestId, [_Other | Rest]) ->
    find_request_handler(RequestId, Rest).

%% OTP 27 exposed the id at the top level; OTP 29 nests it under
%% current_request. Accepting both layouts keeps this narrowly confined use of
%% the internal diagnostic API compatible across Loom's supported floor.
handler_owns_request(RequestId, Info) ->
    case lists:keyfind(id, 1, Info) of
        {id, RequestId} -> true;
        _ ->
            Current = proplists:get_value(current_request, Info, []),
            lists:keyfind(id, 1, Current) =:= {id, RequestId}
    end.

finish_native(_RequestId, undefined, undefined) ->
    ok;
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
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    end.

conservative_cancel(RequestId) ->
    try httpc:cancel_request(RequestId)
    catch
        _:_ -> ok
    end.

%% An unavailable handler supervisor is not evidence that the request drained.
%% Stay alive until the exact handler can be cancelled and monitored or a
%% successful scan proves that no child retains the request id.
await_discovery(RequestId) ->
    case request_handler(RequestId) of
        {ok, Handler} ->
            Monitor = erlang:monitor(process, Handler),
            finish_native(RequestId, Handler, Monitor);
        gone -> ok;
        discovery_failed ->
            receive after 10 -> await_discovery(RequestId) end
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
