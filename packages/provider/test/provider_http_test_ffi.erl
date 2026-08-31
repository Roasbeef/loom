%% A loopback HTTP peer used to prove that production cancellation reaches
%% the socket rather than merely retiring Loom's local waiter.
-module(provider_http_test_ffi).
-export([start_hanging_server/2, start_fast_server/0, start_malformed_server/0,
         start_body_server/1,
         start_redirect_pair/1, stop_servers/1,
         restart_httpc_manager/0, restart_httpc_handler_supervisor/0,
         with_suspended_request_handlers/2, await_owner_drain_wait/1]).

%% Waits until cancellation has moved the native owner into its handler-Down
%% barrier. This is a test observation, not production coordination: it makes
%% the Gleam assertion prove that an already-processed cancel cannot retire the
%% owner before the suspended handler releases its socket.
await_owner_drain_wait(Owner) ->
    await_owner_drain_wait(Owner, 1000).

await_owner_drain_wait(_Owner, 0) ->
    erlang:error(owner_did_not_enter_drain_wait);
await_owner_drain_wait(Owner, Remaining) ->
    case process_info(Owner, current_function) of
        {current_function, {provider_ffi, await_process, 2}} -> nil;
        undefined -> erlang:error(owner_exited_before_drain_wait);
        _ ->
            receive after 1 ->
                await_owner_drain_wait(Owner, Remaining - 1)
            end
    end.

%% Replaces only the default manager generation. Request handlers live under
%% their own supervisor, which is exactly why manager death cannot stand in for
%% request drain.
restart_httpc_manager() ->
    Old = whereis(httpc_manager),
    exit(Old, kill),
    await_replacement_manager(Old, 1000),
    nil.

%% Replaces the handler supervisor without touching its unlinked children.
%% This recreates the OTP topology that made a supervisor-only scan unsound:
%% the live request remains owned by a handler the replacement supervisor has
%% never seen.
restart_httpc_handler_supervisor() ->
    Old = whereis(httpc_handler_sup),
    exit(Old, kill),
    await_replacement(httpc_handler_sup, Old, 1000),
    nil.

await_replacement_manager(_Old, 0) ->
    erlang:error(httpc_manager_did_not_restart);
await_replacement_manager(Old, Remaining) ->
    await_replacement(httpc_manager, Old, Remaining).

await_replacement(_Name, _Old, 0) ->
    erlang:error(httpc_process_did_not_restart);
await_replacement(Name, Old, Remaining) ->
    case whereis(Name) of
        New when is_pid(New), New =/= Old -> ok;
        _ -> receive after 1 ->
                 await_replacement(Name, Old, Remaining - 1)
             end
    end.

%% The native owner monitors only the handler captured for this request.
%% Suspending that closed set cannot affect another test's request, and the after clause
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
    case process_info(Owner, monitors) of
        {monitors, []} ->
            receive after 1 -> await_request_handlers(Owner, Remaining - 1) end;
        {monitors, Monitors} ->
            Handlers = [Pid || {process, Pid} <- Monitors,
                               is_request_handler(Pid)],
            case Handlers of
                [] ->
                    receive after 1 ->
                        await_request_handlers(Owner, Remaining - 1)
                    end;
                _ -> Handlers
            end;
        undefined -> []
    end.

is_request_handler(Pid) ->
    try
        Info = httpc_handler:info(Pid),
        lists:keymember(id, 1, Info) orelse
            lists:keymember(
              id, 1, proplists:get_value(current_request, Info, []))
    catch
        _:_ -> false
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

%% Answers and closes in the same scheduler slice when possible. This makes the
%% response race the native owner's post-admission handler capture instead of
%% relying on a sleep to approximate the vulnerable ordering.
start_fast_server() ->
    {ok, Listener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        ok = gen_tcp:close(Listener),
        {ok, _Request} = gen_tcp:recv(Socket, 0, 2000),
        ok = gen_tcp:send(
               Socket,
               <<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n",
                 "Connection: close\r\n\r\n">>),
        ok = gen_tcp:close(Socket)
    end),
    {Port, Server}.

start_body_server(Size) ->
    {ok, Listener} =
        gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        ok = gen_tcp:close(Listener),
        {ok, _Request} = gen_tcp:recv(Socket, 0, 2000),
        Header = ["HTTP/1.1 200 OK\r\nContent-Length: ",
                  integer_to_binary(Size),
                  "\r\nConnection: close\r\n\r\n"],
        ok = gen_tcp:send(Socket, Header),
        _ = gen_tcp:send(Socket, binary:copy(<<"x">>, Size)),
        gen_tcp:close(Socket)
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
