%% A loopback HTTP peer used to prove that production cancellation reaches
%% the socket rather than merely retiring Loom's local waiter.
-module(provider_http_test_ffi).
-export([start_hanging_server/2, start_malformed_server/0,
         start_redirect_pair/1, stop_servers/1,
         with_suspended_request_handlers/2]).

%% The native owner links only the handler captured for this request. Suspending
%% that closed set cannot affect another test's request, and the after clause
%% prevents a failed Gleam assertion from poisoning the remainder of the suite.
with_suspended_request_handlers(Owner, Test) ->
    Handlers = await_request_handlers(Owner, 1000),
    lists:foreach(fun(Pid) -> true = erlang:suspend_process(Pid) end, Handlers),
    try Test(Handlers)
    after
        lists:foreach(fun resume_if_alive/1, Handlers)
    end,
    nil.

await_request_handlers(_Owner, 0) ->
    [];
await_request_handlers(Owner, Remaining) ->
    case process_info(Owner, links) of
        {links, []} ->
            receive after 1 -> await_request_handlers(Owner, Remaining - 1) end;
        {links, Handlers} -> Handlers;
        undefined -> []
    end.

resume_if_alive(Pid) ->
    case is_process_alive(Pid) of
        true -> erlang:resume_process(Pid);
        false -> true
    end.

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

start_redirect_pair(OnTargetAccepted) ->
    {ok, TargetListener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_TargetAddress, TargetPort}} = inet:sockname(TargetListener),
    Target = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(TargetListener),
        ok = gen_tcp:close(TargetListener),
        OnTargetAccepted(),
        wait_for_close(Socket, fun() -> nil end)
    end),
    {ok, RedirectListener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_RedirectAddress, RedirectPort}} = inet:sockname(RedirectListener),
    Redirect = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(RedirectListener),
        ok = gen_tcp:close(RedirectListener),
        {ok, _Request} = gen_tcp:recv(Socket, 0, 2000),
        Location = io_lib:format("http://127.0.0.1:~B/hang", [TargetPort]),
        Response = ["HTTP/1.1 302 Found\r\nLocation: ", Location,
                    "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"],
        ok = gen_tcp:send(Socket, Response),
        ok = gen_tcp:close(Socket)
    end),
    {RedirectPort, [Redirect, Target]}.

stop_servers(Pids) ->
    lists:foreach(fun(Pid) -> exit(Pid, kill) end, Pids),
    nil.
