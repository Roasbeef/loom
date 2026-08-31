%% Erlang shims for the codemode package (house rule: one flat FFI module
%% per package; every function here is reached only through the Gleam
%% externals in codemode/internal/ffi_*.gleam).
%%
%% The whole of it is the broker end of one AF_UNIX capability socket: the
%% link a jailed satellite node connects back on. Options mirror the
%% satellite side in cap_ffi:connect_unix/1 exactly — binary, passive,
%% raw packets — because the two ends must agree that Gleam, not the port
%% driver, owns frame boundaries.
%%
%% Each shim converts to Gleam conventions at the boundary: exceptions are
%% caught, results come back as {ok, X} | {error, E}, and error reasons are
%% rendered to binaries so the Gleam side stays total and printable.
-module(codemode_ffi).

-export([
    listen_unix/1,
    accept_unix/2,
    socket_recv/1,
    socket_send/2,
    socket_close/1,
    listener_close/1
]).

%% gen_tcp:listen/2 with an {ifaddr, {local, Path}} address — the BEAM's
%% only route to an AF_UNIX listener. A stale socket file from a crashed
%% previous run is unlinked first; bind(2) refuses an existing path even
%% when nothing is listening on it. backlog 1 is deliberate: exactly one
%% satellite per execution ever connects.
listen_unix(Path) ->
    try
        PathList = unicode:characters_to_list(Path),
        _ = file:delete(PathList),
        Options = [
            {ifaddr, {local, PathList}},
            binary,
            {active, false},
            {packet, raw},
            {backlog, 1}
        ],
        case gen_tcp:listen(0, Options) of
            {ok, Listener} -> {ok, Listener};
            {error, Reason} -> {error, describe(Reason)}
        end
    catch
        _:Error -> {error, describe(Error)}
    end.

%% gen_tcp:accept/2. A timeout is its own Gleam variant (the atom
%% accept_timeout) rather than an error string, so the caller can poll:
%% between attempts it checks whether the node it launched has already
%% died, which is the only way to notice a satellite that never connects.
accept_unix(Listener, TimeoutMs) ->
    try
        case gen_tcp:accept(Listener, TimeoutMs) of
            {ok, Socket} -> {ok, Socket};
            {error, timeout} -> {error, accept_timeout};
            {error, Reason} -> {error, {accept_failed, describe(Reason)}}
        end
    catch
        _:Error -> {error, {accept_failed, describe(Error)}}
    end.

%% gen_tcp:recv/2 with length 0: block until some bytes arrive on the
%% passive socket and return whatever is available. A closed peer is the
%% ordinary end of an execution, so it is described plainly rather than as
%% a fault. Callable only by the process that accepted the socket.
socket_recv(Socket) ->
    try
        case gen_tcp:recv(Socket, 0) of
            {ok, Data} -> {ok, Data};
            {error, closed} -> {error, <<"the cap channel reached end of stream">>};
            {error, Reason} -> {error, describe(Reason)}
        end
    catch
        _:Error -> {error, describe(Error)}
    end.

%% gen_tcp:send/2 — write a whole frame. Callable from a process other
%% than the socket's owner, which is what lets the writer process serve
%% the host's outbound frames while the reader blocks in recv.
socket_send(Socket, Bytes) ->
    try
        case gen_tcp:send(Socket, Bytes) of
            ok -> {ok, nil};
            {error, Reason} -> {error, describe(Reason)}
        end
    catch
        _:Error -> {error, describe(Error)}
    end.

%% gen_tcp:close/1 on an accepted connection. Closing is what unblocks the
%% reader and what the satellite observes as EOF, so it is the teardown
%% primitive; idempotent from the caller's view.
socket_close(Socket) ->
    try gen_tcp:close(Socket) of
        _ -> nil
    catch
        _:_ -> nil
    end.

%% gen_tcp:close/1 on the listener. Unblocks an accept in flight; does not
%% unlink the socket file, which the Gleam side removes explicitly.
listener_close(Listener) ->
    try gen_tcp:close(Listener) of
        _ -> nil
    catch
        _:_ -> nil
    end.

%% Renders any Erlang error term as a printable binary, so no Gleam
%% signature has to admit a Dynamic.
describe(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
