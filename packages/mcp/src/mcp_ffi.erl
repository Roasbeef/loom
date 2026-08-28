%% Erlang shims for the mcp package (house rule: one flat FFI module per
%% package; every function here is reached only through the Gleam
%% externals in mcp/internal/ffi_port.gleam).
%%
%% Each shim converts to Gleam conventions at the boundary: exceptions
%% are caught and returned as {ok, X} | {error, nil}, and raw terms are
%% normalized into the tuple shapes of the Gleam types declared on the
%% other side of the external.
-module(mcp_ffi).

-export([
    open_stdio/4,
    port_send/2,
    close_port/1,
    port_os_pid/1,
    kill_os_process/1,
    port_event/1
]).

%% erlang:open_port/2 with spawn_executable — the only way to run and
%% stream to an OS process from the BEAM without a NIF. Options: binary
%% frames both ways, stream mode (mcp/stdio owns line boundaries),
%% exit_status so server death is a message, and hide to suppress a
%% console window on other platforms. Env pairs and the working
%% directory arrive as Gleam strings (binaries) and are converted to the
%% charlists open_port's env option requires. Deliberately absent:
%% stderr_to_stdout, which would interleave the server's diagnostics
%% into the JSON-RPC line stream and corrupt framing.
open_stdio(Executable, Args, Env, Cd) ->
    try
        Base = [
            {args, Args},
            {env, env_pairs(Env)},
            binary,
            stream,
            exit_status,
            hide
        ],
        Options =
            case Cd of
                none -> Base;
                {some, Dir} -> [{cd, unicode:characters_to_list(Dir)} | Base]
            end,
        Port = erlang:open_port(
            {spawn_executable, unicode:characters_to_list(Executable)},
            Options
        ),
        {ok, Port}
    catch
        _:_ -> {error, nil}
    end.

env_pairs(Env) ->
    [
        {unicode:characters_to_list(Name), unicode:characters_to_list(Value)}
     || {Name, Value} <- Env
    ].

%% erlang:port_command/2 — write one framed line to the server's stdin.
%% Raises badarg once the port is closed; that is normalized to an error
%% so the client actor settles the call in-band instead of crashing.
port_send(Port, Line) ->
    try
        true = erlang:port_command(Port, Line),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_close/1 — closes the server's stdio, which is the stdio
%% transport's shutdown signal (EOF on the server's stdin). Already
%% closed ports raise badarg; closing is idempotent from the caller's
%% view.
close_port(Port) ->
    try
        erlang:port_close(Port),
        nil
    catch
        _:_ -> nil
    end.

%% erlang:port_info/2 with os_pid — the server's OS pid, kept so `stop`
%% can kill a server that ignores EOF on its stdin.
port_os_pid(Port) ->
    case catch erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid) -> {ok, Pid};
        _ -> {error, nil}
    end.

%% os:cmd/1 running kill(1) — the BEAM has no direct kill(2) binding
%% without a NIF; belt-and-braces after the stdin close, for a server
%% that does not exit on EOF.
kill_os_process(Pid) when is_integer(Pid), Pid > 1 ->
    _ = os:cmd("kill -KILL " ++ integer_to_list(Pid)),
    nil;
kill_os_process(_) ->
    nil.

%% Normalizes a raw port message (received via a record selector on the
%% port) into the mcp/internal/ffi_port.PortEvent shape. Pure term
%% inspection; it lives here because the message arrives as a Dynamic
%% whose shape only Erlang pattern matching can take apart safely.
port_event(Msg) ->
    case Msg of
        {Port, {data, Bin}} when is_port(Port), is_binary(Bin) ->
            {port_bytes, Bin};
        {Port, {exit_status, Status}} when is_port(Port), is_integer(Status) ->
            {port_closed, Status};
        _ ->
            port_junk
    end.
