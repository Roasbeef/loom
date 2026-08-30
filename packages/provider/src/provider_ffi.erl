%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([start_stream_request/8, cancel_stream_request/1, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).

%% os:getenv/1 returns false | string(); normalize to Gleam's
%% {ok, Binary} | {error, nil}.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Starts one HTTP request via httpc:request/4 with {sync, false} and
%% {stream, self}: 2xx bodies arrive chunked as {http, {Id, stream_start
%% | stream | stream_end, ...}} messages, while non-streamable responses
%% (error statuses) arrive as one complete {http, {Id, Result}} message.
%% Both shapes are normalized into the same callback sequence. The request id
%% is returned as an opaque value so typed Gleam code can own cancellation and
%% monitoring without decoding OTP's private identifier.
start_stream_request(Method, Url, Headers, Body,
                     OnStatus, OnChunk, OnEnd, OnFailure) ->
    try
        Receiver = spawn(fun() ->
            receive
                {request_id, RequestId} ->
                    receive_loop(RequestId, OnStatus, OnChunk,
                                 OnEnd, OnFailure)
            end
        end),
        start_native_request(Receiver, Method, Url, Headers, Body)
    catch
        _Class:_CaughtReason ->
            {error, <<"http request owner failed to start">>}
    end.

%% Cancels an opaque native request. Cancellation is safe after completion and
%% returns only after the request's dedicated handler has stopped.
cancel_stream_request(Request) ->
    cancel_native(Request),
    nil.

start_native_request(Receiver, Method, Url, Headers, Body) ->
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
        HttpOptions = migration_safe_http_options(),
        %% A non-empty socket option forces httpc to allocate a fresh handler
        %% instead of reusing a keep-alive session. That gives this request one
        %% monitorable native owner whose DOWN is a socket-drain acknowledgement.
        Options = [{sync, false}, {stream, self}, {body_format, binary},
                   {receiver, Receiver}, {socket_opts, [{nodelay, true}]}],
        case httpc:request(method_atom(Method), Request, HttpOptions, Options) of
            {ok, RequestId} ->
                Receiver ! {request_id, RequestId},
                Handler = request_handler(RequestId, Receiver),
                {ok, {Receiver, {RequestId, Handler, Receiver}}};
            {error, _Reason} ->
                exit(Receiver, kill),
                {error, <<"http request startup failed">>}
        end
    catch
        _Class:_CaughtReason ->
            exit(Receiver, kill),
            {error, <<"http request startup failed">>}
    end.

receive_loop(RequestId, OnStatus, OnChunk, OnEnd, OnFailure) ->
    receive
        {http, {RequestId, stream_start, Headers}} ->
            OnStatus(200, normalize_headers(Headers)),
            receive_loop(RequestId, OnStatus, OnChunk, OnEnd, OnFailure);
        {http, {RequestId, stream, Chunk}} ->
            OnChunk(Chunk),
            receive_loop(RequestId, OnStatus, OnChunk, OnEnd, OnFailure);
        {http, {RequestId, stream_end, _Headers}} ->
            OnEnd();
        {http, {RequestId, {{_Version, Status, _Reason}, Headers, ResponseBody}}} ->
            OnStatus(Status, normalize_headers(Headers)),
            OnChunk(ResponseBody),
            OnEnd();
        {http, {RequestId, {error, _Reason}}} ->
            OnFailure(<<"http transport failed">>)
    after ?RESPONSE_TIMEOUT ->
        cast_cancel_native(RequestId),
        OnFailure(<<"timed out waiting for the http response">>)
    end.

cancel_native({RequestId, Handler, Receiver}) ->
    HandlerMonitor = monitor_handler(Handler),
    ReceiverMonitor = erlang:monitor(process, Receiver),
    try
        cast_cancel_native(RequestId),
        await_handler(HandlerMonitor),
        exit(Receiver, kill),
        await_receiver(ReceiverMonitor),
        ok
    catch
        _Class:_CaughtReason ->
            await_handler(HandlerMonitor),
            exit(Receiver, kill),
            await_receiver(ReceiverMonitor),
            ok
    end.

cast_cancel_native(RequestId) ->
    _ = httpc:cancel_request(RequestId),
    ok.

%% httpc cancellation is an asynchronous manager cast. Capture the dedicated
%% handler before exposing the request id, then wait for its DOWN after cancel;
%% the handler closes its socket in terminate/2 before that signal is emitted.
request_handler(RequestId, Receiver) ->
    try
        case httpc:info() of
            Info when is_list(Info) ->
                Handlers = proplists:get_value(handlers, Info, []),
                case find_request_handler(RequestId, Handlers) of
                    undefined -> retry_request_handler(RequestId, Receiver);
                    Handler -> Handler
                end;
            {error, _Reason} ->
                retry_request_handler(RequestId, Receiver)
        end
    catch
        _Class:_CaughtReason -> retry_request_handler(RequestId, Receiver)
    end.

%% The request has already been admitted when handler discovery runs. If the
%% manager is restarting, keep the custodian inside startup and retry instead
%% of returning an owner that could later fabricate a drain acknowledgement.
retry_request_handler(RequestId, Receiver) ->
    case is_process_alive(Receiver) of
        false -> undefined;
        true ->
            receive
            after 10 -> request_handler(RequestId, Receiver)
            end
    end.

find_request_handler(_RequestId, []) ->
    undefined;
find_request_handler(RequestId, [{Pid, RequestIds, _Info} | Rest]) ->
    case lists:member(RequestId, RequestIds) of
        true -> Pid;
        false -> find_request_handler(RequestId, Rest)
    end.

monitor_handler(undefined) ->
    undefined;
monitor_handler(Handler) ->
    erlang:monitor(process, Handler).

await_handler(undefined) ->
    ok;
await_handler(Monitor) ->
    receive
        {'DOWN', Monitor, process, _Handler, _Reason} -> ok
    end.

await_receiver(Monitor) ->
    receive
        {'DOWN', Monitor, process, _Receiver, _Reason} -> ok
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
