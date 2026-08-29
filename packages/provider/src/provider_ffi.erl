%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([start_stream_request/8, cancel_stream_request/1, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).

%% A cancellation exchange is local to the VM and the request owner never
%% performs blocking work after startup. Keep the caller bounded anyway: a
%% wedged owner must not wedge the provider gateway that is trying to stop it.
-define(CANCEL_TIMEOUT, 1000).

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
%% Both shapes are normalized into the same callback sequence. The spawned
%% owner retains the exact RequestId and monitors the Gleam request owner;
%% explicit cancellation and owner death therefore both reach
%% httpc:cancel_request/1. It is returned immediately so cancellation can
%% queue during startup; startup failures are reported through one constant,
%% redacted failure callback.
start_stream_request(Method, Url, Headers, Body,
                     OnStatus, OnChunk, OnEnd, OnFailure) ->
    try
        Parent = self(),
        Owner = spawn(fun() ->
            start_stream_owner(Parent, Method, Url, Headers, Body,
                               OnStatus, OnChunk, OnEnd, OnFailure)
        end),
        {ok, Owner}
    catch
        _Class:_CaughtReason ->
            {error, <<"http request owner failed to start">>}
    end.

%% Asks the owner to cancel the exact RequestId it retained. The monitor
%% makes cancellation idempotent after normal completion, and the bounded
%% receive prevents a broken owner from blocking its gateway indefinitely.
cancel_stream_request(Owner) ->
    Reply = make_ref(),
    Monitor = erlang:monitor(process, Owner),
    Owner ! {cancel, self(), Reply},
    receive
        {Reply, cancelled} ->
            erlang:demonitor(Monitor, [flush]);
        {'DOWN', Monitor, process, Owner, _Reason} ->
            ok
    after ?CANCEL_TIMEOUT ->
        erlang:demonitor(Monitor, [flush])
    end,
    nil.

start_stream_owner(Parent, Method, Url, Headers, Body,
                   OnStatus, OnChunk, OnEnd, OnFailure) ->
    ParentMonitor = erlang:monitor(process, Parent),
    try
        {ok, _} = application:ensure_all_started(inets),
        {ok, _} = application:ensure_all_started(ssl),
        HeaderList = [{unicode:characters_to_list(K), unicode:characters_to_list(V)}
                      || {K, V} <- Headers],
        UrlList = unicode:characters_to_list(Url),
        Request =
            case Method of
                <<"GET">> -> {UrlList, HeaderList};
                _ -> {UrlList, HeaderList, content_type(HeaderList), Body}
            end,
        HttpOptions = [{timeout, ?RESPONSE_TIMEOUT}, {connect_timeout, 30000}],
        Options = [{sync, false}, {stream, self}, {body_format, binary}],
        case httpc:request(method_atom(Method), Request, HttpOptions, Options) of
            {ok, RequestId} ->
                receive_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure);
            {error, _Reason} ->
                OnFailure(<<"http request startup failed">>)
        end
    catch
        _Class:_CaughtReason ->
            OnFailure(<<"http request startup failed">>)
    end.

receive_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure) ->
    receive
        {http, {RequestId, stream_start, Headers}} ->
            OnStatus(200, normalize_headers(Headers)),
            receive_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                         OnEnd, OnFailure);
        {http, {RequestId, stream, Chunk}} ->
            OnChunk(Chunk),
            receive_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                         OnEnd, OnFailure);
        {http, {RequestId, stream_end, _Headers}} ->
            OnEnd();
        {http, {RequestId, {{_Version, Status, _Reason}, Headers, ResponseBody}}} ->
            OnStatus(Status, normalize_headers(Headers)),
            OnChunk(ResponseBody),
            OnEnd();
        {http, {RequestId, {error, Reason}}} ->
            OnFailure(describe(Reason));
        {cancel, From, Reply} ->
            ok = httpc:cancel_request(RequestId),
            From ! {Reply, cancelled};
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            ok = httpc:cancel_request(RequestId)
    after ?RESPONSE_TIMEOUT ->
        ok = httpc:cancel_request(RequestId),
        OnFailure(<<"timed out waiting for the http response">>)
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

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
