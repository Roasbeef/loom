%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([stream_request/8, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).

%% os:getenv/1 returns false | string(); normalize to Gleam's
%% {ok, Binary} | {error, nil}.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Streams one HTTP request via httpc:request/4 with {sync, false} and
%% {stream, self}: 2xx bodies arrive chunked as {http, {Id, stream_start
%% | stream | stream_end, ...}} messages, while non-streamable responses
%% (error statuses) arrive as one complete {http, {Id, Result}} message.
%% Both shapes are normalized into the same callback sequence. Exceptions
%% from httpc are caught and reported through OnFailure, never thrown.
stream_request(Method, Url, Headers, Body, OnStatus, OnChunk, OnEnd, OnFailure) ->
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
                receive_loop(RequestId, OnStatus, OnChunk, OnEnd, OnFailure);
            {error, Reason} ->
                OnFailure(describe(Reason))
        end
    catch
        Class:CaughtReason -> OnFailure(describe({Class, CaughtReason}))
    end,
    nil.

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
        {http, {RequestId, {error, Reason}}} ->
            OnFailure(describe(Reason))
    after ?RESPONSE_TIMEOUT ->
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
