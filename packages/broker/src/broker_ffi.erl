%% Erlang shims for the broker package (house rule: one flat FFI module
%% per package; every function here is reached only through the Gleam
%% externals in broker/internal/ffi_*.gleam).
%%
%% Each shim converts to Gleam conventions at the boundary: exceptions
%% are caught and returned as {ok, X} | {error, nil}, and raw terms are
%% normalized into the tuple shapes of the Gleam types declared on the
%% other side of the external.
-module(broker_ffi).

-export([
    strong_rand_bytes/1,
    constant_time_equal/2,
    open_helper/2,
    port_send/2,
    close_port/1,
    port_os_pid/1,
    kill_os_process/1,
    write_private_file/3,
    delete_file/1,
    port_event/1,
    os_name/0,
    schedulers_online/0
]).

%% crypto:strong_rand_bytes/1 — a cryptographically strong entropy
%% source for capability token minting.
strong_rand_bytes(Count) when is_integer(Count), Count >= 0 ->
    crypto:strong_rand_bytes(Count).

%% crypto:hash_equals/2 — constant-time byte comparison, so checking a
%% presented capability token leaks no timing information about how many
%% leading bytes matched. hash_equals raises badarg on length mismatch;
%% lengths are public (all tokens are 32 bytes), so unequal lengths are
%% simply not equal.
constant_time_equal(A, B) when is_binary(A), is_binary(B) ->
    case byte_size(A) =:= byte_size(B) of
        true -> crypto:hash_equals(A, B);
        false -> false
    end.

%% erlang:open_port/2 with spawn_executable — the only way to run and
%% stream to an OS process from the BEAM without a NIF. Options: binary
%% frames both ways, stream mode (the broker's own deframer owns frame
%% boundaries), exit_status so channel death is a message, and hide to
%% suppress a console window on other platforms.
open_helper(Executable, Args) ->
    try
        Port = erlang:open_port(
            {spawn_executable, unicode:characters_to_list(Executable)},
            [{args, Args}, binary, stream, exit_status, hide]
        ),
        {ok, Port}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_command/2 — write bytes to the helper's stdin. Raises
%% badarg once the port is closed; that is normalized to an error so the
%% caller settles the effect in-band instead of crashing.
port_send(Port, Bytes) ->
    try
        true = erlang:port_command(Port, Bytes),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_close/1 — closes the helper's stdio. The helper treats
%% channel close as an order to reap any running jail. Already-closed
%% ports raise badarg; closing is idempotent from the caller's view.
close_port(Port) ->
    try
        erlang:port_close(Port),
        nil
    catch
        _:_ -> nil
    end.

%% erlang:port_info/2 with os_pid — the helper's OS pid, kept for the
%% broker-side cancel escalation (SIGKILL as the last resort).
port_os_pid(Port) ->
    case catch erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid) -> {ok, Pid};
        _ -> {error, nil}
    end.

%% os:cmd/1 running kill(1) — the BEAM has no direct kill(2) binding
%% without a NIF; this is the belt-and-braces escalation used only after
%% the helper missed its own 2-second TERM-to-KILL ladder.
kill_os_process(Pid) when is_integer(Pid), Pid > 1 ->
    _ = os:cmd("kill -KILL " ++ integer_to_list(Pid)),
    nil;
kill_os_process(_) ->
    nil.

%% filelib:ensure_path/1 + file:write_file/3 + file:change_mode/2 —
%% creates Dir (mode 0700) and writes Name inside it exclusively, then
%% tightens the file to 0600. The directory is chmodded before the file
%% is written so the policy bytes are never readable by other users,
%% even between create and chmod of the file itself.
write_private_file(Dir, Name, Bytes) ->
    try
        DirList = unicode:characters_to_list(Dir),
        ok = filelib:ensure_path(DirList),
        ok = file:change_mode(DirList, 8#700),
        Path = filename:join(DirList, unicode:characters_to_list(Name)),
        ok = file:write_file(Path, Bytes, [exclusive, raw]),
        ok = file:change_mode(Path, 8#600),
        {ok, unicode:characters_to_binary(Path)}
    catch
        _:_ -> {error, nil}
    end.

%% file:delete/1 — removes the temp policy file once the helper has read
%% it (signalled by the helper's hello). Idempotent: a missing file is
%% success.
delete_file(Path) ->
    _ = file:delete(unicode:characters_to_list(Path)),
    nil.

%% os:type/0's name half, as a binary ("linux", "darwin", "nt"). An
%% ambient fact of the running system with no pure answer, fixed for the
%% life of the node. No normalization happens here: deciding what a name
%% means for the jail is a decision, and decisions belong in Gleam.
os_name() ->
    {_Family, Name} = os:type(),
    atom_to_binary(Name, utf8).

%% erlang:system_info(schedulers_online) — how many schedulers this node
%% is actually running on, which is the closest the BEAM comes to
%% "how big is this machine". Used only to size the helper pool's
%% default ceiling; the clamping that turns it into a pool size is a
%% decision and stays in Gleam.
schedulers_online() ->
    erlang:system_info(schedulers_online).

%% Normalizes a raw port message (received via a record selector on the
%% port) into the broker/internal/ffi_port.PortEvent shape. Pure term
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
