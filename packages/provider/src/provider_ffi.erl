%% Erlang shims for the provider package. All FFI externals live in
%% provider/internal/ffi_*.gleam and bind here; this module converts
%% between Erlang conventions (charlists, raw httpc messages) and the
%% Gleam callback signatures at the boundary, per the house FFI rules.
-module(provider_ffi).
-export([prepare_stream_request/4, begin_stream_request/5,
         cancel_stream_request/1, get_env/1]).

%% Total receive-loop timeout for one streamed response, in milliseconds.
-define(RESPONSE_TIMEOUT, 300000).
-define(DISCOVERY_TIMEOUT, 25).
-define(DISCOVERY_RETRY, 10).

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
        Options = [{sync, false}, {stream, self}, {body_format, binary},
                   {receiver, self()}, {socket_opts, [{nodelay, true}]}],
        Admission =
            try httpc:request(method_atom(Method), Request,
                              migration_safe_http_options(), Options)
            catch
                _:_ -> interrupted
            end,
        case Admission of
            {ok, RequestId} ->
                enter_native_loop(RequestId, ParentMonitor,
                                  OnStatus, OnChunk, OnEnd, OnFailure);
            {error, _Reason} ->
                start_failed(Manager, HandlerSupervisor, ParentMonitor,
                             OnStatus, OnChunk, OnEnd, OnFailure);
            interrupted ->
                start_failed(Manager, HandlerSupervisor, ParentMonitor,
                             OnStatus, OnChunk, OnEnd, OnFailure)
        end
    catch
        _Class:_CaughtReason ->
            safe_callback(OnFailure, [<<"http request startup failed">>])
    end.

%% A failed public call is conclusive only while the manager and handler
%% supervisor generations which received it remain alive. If either changed,
%% the manager may have admitted a handler before losing its reply. This owner
%% must then stay as the witness until that handler identifies itself through a
%% raw response; exiting here would turn an ambiguous admission into false
%% drain.
start_failed(Manager, HandlerSupervisor, ParentMonitor,
             OnStatus, OnChunk, OnEnd, OnFailure) ->
    case same_generation(httpc_manager, Manager) andalso
         same_generation(httpc_handler_sup, HandlerSupervisor) of
        true ->
            safe_callback(OnFailure, [<<"http request startup failed">>]);
        false ->
            ambiguous_native_loop(ParentMonitor, OnStatus, OnChunk,
                                  OnEnd, OnFailure, false)
    end.

same_generation(Name, Pid) when is_pid(Pid) ->
    whereis(Name) =:= Pid andalso is_process_alive(Pid);
same_generation(_Name, _Pid) ->
    false.

ambiguous_native_loop(ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure,
                      Stopping) ->
    receive
        {http, {RequestId, _} = Message} ->
            enter_native_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                              OnEnd, OnFailure, Message, Stopping);
        {http, {RequestId, _, _} = Message} ->
            enter_native_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                              OnEnd, OnFailure, Message, Stopping);
        {http, {RequestId, _, _, _} = Message} ->
            enter_native_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                              OnEnd, OnFailure, Message, Stopping);
        cancel ->
            ambiguous_native_loop(ParentMonitor, OnStatus, OnChunk, OnEnd,
                                  OnFailure, true);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            ambiguous_native_loop(ParentMonitor, OnStatus, OnChunk, OnEnd,
                                  OnFailure, true)
    after ?RESPONSE_TIMEOUT ->
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

enter_native_loop(RequestId, ParentMonitor,
                  OnStatus, OnChunk, OnEnd, OnFailure) ->
    enter_native_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                      OnFailure, none, false).

enter_native_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                  OnFailure, FirstMessage, Stopping) ->
    start_handler_discovery(RequestId),
    case FirstMessage of
        none ->
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, false, Stopping);
        Message ->
            discovery_http(Message, RequestId, ParentMonitor, OnStatus,
                           OnChunk, OnEnd, OnFailure, false, Stopping)
    end.

start_handler_discovery(RequestId) ->
    Owner = self(),
    spawn(fun() ->
        Owner ! {handler_discovery, RequestId, request_handler(RequestId)}
    end),
    ok.

discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                 OnFailure, Terminal, Stopping) ->
    receive
        {handler_discovery, RequestId, {ok, Handler}} ->
            HandlerMonitor = erlang:monitor(process, Handler),
            case Terminal orelse Stopping of
                true -> finish_native(RequestId, Handler, HandlerMonitor);
                false -> native_loop(RequestId, Handler, HandlerMonitor,
                                     ParentMonitor, OnStatus, OnChunk,
                                     OnEnd, OnFailure)
            end;
        {handler_discovery, RequestId, gone} ->
            case Terminal orelse Stopping of
                true -> ok;
                false ->
                    %% A fast handler can queue its terminal and disappear
                    %% before discovery observes it. With no native work left,
                    %% keep receiving until that already-owned result or the
                    %% request deadline arrives; absence is drain proof, not a
                    %% reason to replace a valid response with failure.
                    native_loop(RequestId, undefined, undefined,
                                ParentMonitor, OnStatus, OnChunk,
                                OnEnd, OnFailure)
            end;
        {handler_discovery, RequestId, discovery_failed} ->
            erlang:send_after(?DISCOVERY_RETRY, self(),
                              {retry_handler_discovery, RequestId}),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, Terminal, Stopping);
        {retry_handler_discovery, RequestId} ->
            start_handler_discovery(RequestId),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, Terminal, Stopping);
        {http, {RequestId, _} = Message} ->
            discovery_http(Message, RequestId, ParentMonitor, OnStatus,
                           OnChunk, OnEnd, OnFailure, Terminal, Stopping);
        {http, {RequestId, _, _} = Message} ->
            discovery_http(Message, RequestId, ParentMonitor, OnStatus,
                           OnChunk, OnEnd, OnFailure, Terminal, Stopping);
        {http, {RequestId, _, _, _} = Message} ->
            discovery_http(Message, RequestId, ParentMonitor, OnStatus,
                           OnChunk, OnEnd, OnFailure, Terminal, Stopping);
        cancel ->
            conservative_cancel(RequestId),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, Terminal, true);
        {'DOWN', ParentMonitor, process, _Parent, _Reason} ->
            conservative_cancel(RequestId),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, Terminal, true)
    after ?RESPONSE_TIMEOUT ->
        case Terminal of
            true -> ok;
            false -> safe_callback(OnFailure,
                                   [<<"timed out waiting for the http response">>])
        end,
        conservative_cancel(RequestId),
        discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                         OnFailure, true, true)
    end.

discovery_http(_Message, RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
               OnFailure, true, Stopping) ->
    discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                     OnFailure, true, Stopping);
discovery_http({RequestId, stream_start, Headers}, RequestId, ParentMonitor,
               OnStatus, OnChunk, OnEnd, OnFailure, false, Stopping) ->
    case safe_callback(OnStatus, [200, normalize_headers(Headers)]) of
        ok -> discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                               OnEnd, OnFailure, false, Stopping);
        error ->
            conservative_cancel(RequestId),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, false, true)
    end;
discovery_http({RequestId, stream_start, Headers, _Handler}, RequestId,
               ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure, false,
               Stopping) ->
    discovery_http({RequestId, stream_start, Headers}, RequestId,
                   ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure, false,
                   Stopping);
discovery_http({RequestId, stream, Chunk}, RequestId, ParentMonitor, OnStatus,
               OnChunk, OnEnd, OnFailure, false, Stopping) ->
    case safe_callback(OnChunk, [Chunk]) of
        ok -> discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                               OnEnd, OnFailure, false, Stopping);
        error ->
            conservative_cancel(RequestId),
            discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk,
                             OnEnd, OnFailure, false, true)
    end;
discovery_http({RequestId, stream_end, _Headers}, RequestId, ParentMonitor,
               OnStatus, OnChunk, OnEnd, OnFailure, false, Stopping) ->
    safe_callback(OnEnd, []),
    discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                     OnFailure, true, Stopping);
discovery_http({RequestId, {error, _Reason}}, RequestId, ParentMonitor,
               OnStatus, OnChunk, OnEnd, OnFailure, false, Stopping) ->
    safe_callback(OnFailure, [<<"http transport failed">>]),
    discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                     OnFailure, true, Stopping);
discovery_http({RequestId, {{_Version, Status, _Reason}, Headers, Body}},
               RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd, OnFailure,
               false, Stopping) ->
    safe_callback(OnStatus, [Status, normalize_headers(Headers)]),
    safe_callback(OnChunk, [Body]),
    safe_callback(OnEnd, []),
    discovering_loop(RequestId, ParentMonitor, OnStatus, OnChunk, OnEnd,
                     OnFailure, true, Stopping).

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
    find_request_handler(RequestId, erlang:processes(), false).

find_request_handler(_RequestId, [], true) ->
    discovery_failed;
find_request_handler(_RequestId, [], false) ->
    gone;
find_request_handler(RequestId, [Pid | Rest], Unknown) ->
    case is_httpc_handler(Pid) of
        false -> find_request_handler(RequestId, Rest, Unknown);
        true ->
            case bounded_handler_info(Pid) of
                {ok, Info} ->
                    case handler_owns_request(RequestId, Info) of
                        true -> {ok, Pid};
                        false -> find_request_handler(RequestId, Rest, Unknown)
                    end;
                gone -> find_request_handler(RequestId, Rest, Unknown);
                unknown -> find_request_handler(RequestId, Rest, true)
            end
    end.

is_httpc_handler(Pid) ->
    case process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            lists:keyfind('$initial_call', 1, Dictionary) =:=
                {'$initial_call', {httpc_handler, init, 1}};
        undefined -> false
    end.

%% Handler init acknowledges its supervisor before connect enters the gen_server
%% loop, so the public debug helper's infinite call can pin cancellation. A
%% bounded direct call makes a busy candidate `unknown`; only a complete scan
%% of responsive live handlers may return `gone`.
bounded_handler_info(Pid) ->
    try gen_server:call(Pid, info, ?DISCOVERY_TIMEOUT) of
        Info when is_list(Info) -> {ok, Info};
        _Other -> unknown
    catch
        exit:{noproc, _} -> gone;
        exit:{normal, _} -> gone;
        exit:{shutdown, _} -> gone;
        exit:{timeout, _} -> unknown;
        _:_ -> unknown
    end.

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
