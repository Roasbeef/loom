%% A loopback HTTP peer used to prove that production cancellation reaches
%% the socket rather than merely retiring Loom's local waiter.
-module(provider_http_test_ffi).
-export([start_hanging_server/2, start_malformed_server/0,
         suspend_active_handlers/0, resume_handlers/1]).

suspend_active_handlers() ->
    Handlers = proplists:get_value(handlers, httpc:info(), []),
    Pids = [Pid || {Pid, _Requests, _Info} <- Handlers],
    lists:foreach(fun(Pid) -> true = erlang:suspend_process(Pid) end, Pids),
    Pids.

resume_handlers(Pids) ->
    lists:foreach(fun(Pid) -> true = erlang:resume_process(Pid) end, Pids),
    nil.

start_hanging_server(OnAccepted, OnClosed) ->
    {ok, Listener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        ok = gen_tcp:close(Listener),
        OnAccepted(),
        wait_for_close(Socket, OnClosed)
    end),
    {Port, Server}.

wait_for_close(Socket, OnClosed) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, _Bytes} ->
            wait_for_close(Socket, OnClosed);
        {error, closed} ->
            OnClosed();
        {error, _Reason} ->
            ok
    end.

start_malformed_server() ->
    {ok, Listener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        ok = gen_tcp:close(Listener),
        {ok, _Request} = gen_tcp:recv(Socket, 0, 2000),
        ok = gen_tcp:send(Socket, <<"Bearer SECRET_TOKEN\r\n\r\n">>),
        ok = gen_tcp:close(Socket)
    end),
    {Port, Server}.
