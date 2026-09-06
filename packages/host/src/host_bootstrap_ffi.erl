-module(host_bootstrap_ffi).

-include_lib("kernel/include/file.hrl").

%% Every export here is a mechanism no Gleam package reaches. Clocks,
%% digests, the environment, `stat`, directory listing and permission bits
%% used to live here too; they are now Gleam in `host/bootstrap` over
%% `gleam_time`, `gleam_crypto`, `envoy` and `simplifile`, which is why this
%% list is shorter than the module's history suggests.
-export([read_prefix/2, read_bounded/2,
         current_process_id/0, current_uid/0,
         canonical_directory/1, canonical_path/1,
         try_launch_lock/1, release_launch_lock/1,
         atomic_write_private/2, find_executable/1,
         reserve_loopback_port/0,
         spawn_server/4, release_server_process/1, close_server_process/1,
         terminate_process_group/1, process_identity/1,
         current_log_tail/3]).

%% Every path arriving from Gleam is a UTF-8 binary. `binary_to_list/1` would
%% split it one codepoint per byte, so `/tmp/é` would reach `filename`, `file`
%% and `open_port` as `/tmp/Ã©` and a `HOME` or workspace holding an accent
%% would name a directory nobody created. Path and name conversions therefore
%% go through `unicode:characters_to_list/1` in one direction and
%% `unicode:characters_to_binary/1` in the other; only the ASCII hex suffix in
%% `atomic_write_private/2` stays on the byte-wise pair.

%% The endpoint fences the whole VM, not one BEAM process inside it.
current_process_id() ->
    list_to_integer(os:getpid()).

read_prefix(Path, Bytes) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            Result = case file:read_file_info(Handle) of
                {ok, #file_info{type = regular}} ->
                    case file:read(Handle, Bytes) of
                        {ok, Data} -> {ok, Data};
                        eof -> {ok, <<>>};
                        {error, Reason} -> {error, describe(Reason)}
                    end;
                {ok, _} ->
                    {error, <<"not a regular file">>};
                {error, Reason} ->
                    {error, describe(Reason)}
            end,
            _ = file:close(Handle),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

read_bounded(Path, Limit) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Handle} ->
            Result = case file:read_file_info(Handle) of
                {ok, #file_info{type = regular}} ->
                    read_bounded_loop(Handle, Limit, 0, []);
                {ok, _} ->
                    {error, <<"not a regular file">>};
                {error, Reason} ->
                    {error, describe(Reason)}
            end,
            _ = file:close(Handle),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

read_bounded_loop(Handle, Limit, Limit, Chunks) ->
    case file:read(Handle, 1) of
        eof -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        {ok, _} -> {error, <<"file exceeds the bounded read limit">>};
        {error, Reason} -> {error, describe(Reason)}
    end;
read_bounded_loop(Handle, Limit, Total, Chunks) ->
    Remaining = Limit - Total,
    ChunkSize = erlang:min(Remaining, 65536),
    case file:read(Handle, ChunkSize) of
        eof ->
            {ok, iolist_to_binary(lists:reverse(Chunks))};
        {ok, Data} ->
            read_bounded_loop(
                Handle,
                Limit,
                Total + byte_size(Data),
                [Data | Chunks]
            );
        {error, Reason} ->
            {error, describe(Reason)}
    end.

canonical_directory(Path0) ->
    case path_or_cwd(Path0) of
        {error, _} = Error ->
            Error;
        {ok, Path} ->
            Absolute = filename:absname(Path),
            case filelib:is_dir(Absolute) of
                false ->
                    {error, describe({not_a_directory, Absolute})};
                true ->
                    case realpath_executable() of
                        {error, _} = Error -> Error;
                        {ok, Realpath} ->
                            case run_capture(Realpath, [Absolute], 5000) of
                                {ok, Output} ->
                                    resolved_path(Output);
                                {error, _} = Error -> Error
                            end
                    end
            end
    end.

%% realpath answers in bytes. A path that is not UTF-8 must not become a
%% Gleam String, which every later string operation would trip over; the
%% decode is checked here rather than in the caller, once for both callers.
resolved_path(Output) ->
    case unicode:characters_to_binary(Output) of
        Decoded when is_binary(Decoded) ->
            case string:trim(Decoded) of
                <<>> -> {error, <<"realpath returned an empty path">>};
                Resolved -> {ok, Resolved}
            end;
        _ ->
            {error, <<"realpath returned a path that is not UTF-8">>}
    end.

canonical_path(PathBinary) ->
    Path = filename:absname(unicode:characters_to_list(PathBinary)),
    case realpath_executable() of
        {error, _} = Error -> Error;
        {ok, Realpath} ->
            case run_capture(Realpath, [Path], 5000) of
                {ok, Output} ->
                    resolved_path(Output);
                {error, _} = Error -> Error
            end
    end.

try_launch_lock(PathBinary) ->
    Path = unicode:characters_to_list(PathBinary),
    case lock_command(Path) of
        {error, Reason} ->
            {error, describe(Reason)};
        {ok, Executable, Arguments} ->
            try
                Port = open_port(
                    {spawn_executable, Executable},
                    [binary, exit_status, use_stdio, stderr_to_stdout, hide,
                     {args, Arguments}]
                ),
                receive
                    {Port, {data, <<"L", _/binary>>}} -> {ok, Port};
                    {Port, {exit_status, _Status}} -> {error, <<"busy">>}
                after 1000 ->
                    _ = safe_port_close(Port),
                    {error, describe(lock_helper_did_not_settle)}
                end
            catch
                Class:Reason -> {error, describe({Class, Reason})}
            end
    end.

release_launch_lock(Port) ->
    _ = safe_port_close(Port),
    nil.

atomic_write_private(PathBinary, Contents) ->
    Path = unicode:characters_to_list(PathBinary),
    Directory = filename:dirname(Path),
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Temporary = filename:join(Directory, "." ++ filename:basename(Path) ++
                              "." ++ Suffix ++ ".tmp"),
    case file:open(Temporary, [write, binary, raw, exclusive, {mode, 8#600}]) of
        {ok, Handle} ->
            Result = case file:change_mode(Temporary, 8#600) of
                ok -> write_sync_close(Handle, Contents);
                {error, _} = Error ->
                    _ = file:close(Handle),
                    Error
            end,
            case Result of
                ok ->
                    case file:rename(Temporary, Path) of
                        ok -> {ok, nil};
                        {error, Reason} ->
                            _ = file:delete(Temporary),
                            {error, describe(Reason)}
                    end;
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, describe(Reason)}
            end;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

find_executable(CandidateBinary) ->
    Candidate = unicode:characters_to_list(CandidateBinary),
    case lists:member($/, Candidate) of
        true ->
            Absolute = filename:absname(Candidate),
            case is_executable_path(Absolute) of
                true -> {ok, unicode:characters_to_binary(Absolute)};
                false -> {error, describe({not_executable, Candidate})}
            end;
        false ->
            case os:find_executable(Candidate) of
                false -> {error, describe({not_executable, Candidate})};
                Path -> {ok, unicode:characters_to_binary(filename:absname(Path))}
            end
    end.

reserve_loopback_port() ->
    case gen_tcp:listen(0, [inet, {ip, {127, 0, 0, 1}},
                            {active, false}, {reuseaddr, true}]) of
        {ok, Socket} ->
            Result = case inet:sockname(Socket) of
                {ok, {{127, 0, 0, 1}, Port}} -> {ok, Port};
                {ok, Address} -> {error, describe({unexpected_address, Address})};
                {error, Reason} -> {error, describe(Reason)}
            end,
            _ = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

spawn_server(ExecutableBinary, ArgumentBinaries, WorkingBinary, LogBinary) ->
    Executable = unicode:characters_to_list(ExecutableBinary),
    Arguments = lists:map(fun unicode:characters_to_list/1, ArgumentBinaries),
    Working = filename:absname(unicode:characters_to_list(WorkingBinary)),
    Log = filename:absname(unicode:characters_to_list(LogBinary)),
    Script = "IFS= read -r LOOM_RELEASE || exit 0; "
             "exec \"$@\" >> \"$LOOM_LOG\" 2>&1",
    try
        Port = open_port(
            {spawn_executable, "/bin/sh"},
            [binary, exit_status, use_stdio, hide,
             {cd, Working},
             {env, [{"LOOM_LOG", Log}]},
             {args, ["-p", "-c", Script, "loomd", Executable | Arguments]}]
        ),
        case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} -> {ok, {Port, Pid}};
            undefined ->
                _ = safe_port_close(Port),
                {error, <<"server process exited during spawn">>}
        end
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

close_server_process(Port) ->
    _ = safe_port_close(Port),
    nil.

release_server_process(Port) ->
    try
        case erlang:port_command(Port, <<"\n">>) of
            true -> {ok, nil};
            false -> {error, <<"server process rejected its release">>}
        end
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

terminate_process_group(Pid) ->
    Group = "-" ++ integer_to_list(Pid),
    _ = run_capture("/bin/kill", ["-TERM", "--", Group], 2000),
    nil.

process_identity(Pid) when is_integer(Pid), Pid > 1 ->
    case os:type() of
        {unix, linux} -> linux_process_identity(Pid);
        {unix, darwin} -> darwin_process_identity(Pid);
        _ -> {error, <<"automatic local startup is unsupported on this platform">>}
    end;
process_identity(_Pid) ->
    {error, <<"invalid process id">>}.

current_log_tail(PathBinary, StartedAtMs, Limit) ->
    Path = unicode:characters_to_list(PathBinary),
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Modified}}
          when Modified * 1000 >= StartedAtMs - 1000 ->
            case file:open(Path, [read, binary, raw]) of
                {ok, Handle} ->
                    Offset = erlang:max(0, Size - Limit),
                    _ = file:position(Handle, Offset),
                    %% The bytes are handed over untouched. `Offset` is a
                    %% byte position with no regard for codepoint
                    %% boundaries, so a slice of an arbitrary child's
                    %% stdout may begin mid-codepoint; `string:trim/1`
                    %% raises `badarg` on that, which would take down the
                    %% caller on the one path whose job is to report why
                    %% startup failed. Decoding and trimming belong to the
                    %% Gleam side, where the partiality is in the type.
                    Result = case file:read(Handle, Limit) of
                        {ok, Data} -> {ok, Data};
                        eof -> {ok, <<>>};
                        {error, _} -> {error, nil}
                    end,
                    _ = file:close(Handle),
                    Result;
                {error, _} -> {error, nil}
            end;
        _ ->
            {error, nil}
    end.

path_or_cwd(<<>>) ->
    case file:get_cwd() of
        {ok, Path} -> {ok, Path};
        {error, Reason} -> {error, describe(Reason)}
    end;
path_or_cwd(Path) ->
    {ok, unicode:characters_to_list(Path)}.

realpath_executable() ->
    first_executable(["/usr/bin/realpath", "/bin/realpath"]).

first_executable([]) ->
    {error, <<"realpath executable was not found">>};
first_executable([Path | Rest]) ->
    case is_executable_path(Path) of
        true -> {ok, Path};
        false -> first_executable(Rest)
    end.

current_uid() ->
    case run_capture("/usr/bin/id", ["-u"], 2000) of
        {ok, Output} ->
            case string:to_integer(string:trim(Output)) of
                {Uid, <<>>} -> {ok, Uid};
                _ -> {error, <<"id returned an invalid user id">>}
            end;
        {error, _} = Error -> Error
    end.

lock_command(Path) ->
    Script = "printf L; while IFS= read -r LOOM_LOCK_HOLD; do :; done",
    case os:type() of
        {unix, darwin} ->
            % Keep one inode across releases so consecutive owners cannot
            % hold independent locks through the same pathname.
            {ok, "/usr/bin/lockf",
             ["-k", "-t", "0", Path, "/bin/sh", "-p", "-c", Script]};
        {unix, linux} ->
            case first_lock_executable(["/usr/bin/flock", "/bin/flock"]) of
                {ok, Flock} ->
                    {ok, Flock,
                     ["-n", Path, "/bin/sh", "-p", "-c", Script]};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, unsupported_platform}
    end.

first_lock_executable([]) ->
    {error, lock_utility_not_found};
first_lock_executable([Path | Rest]) ->
    case is_executable_path(Path) of
        true -> {ok, Path};
        false -> first_lock_executable(Rest)
    end.

write_sync_close(Handle, Contents) ->
    case file:write(Handle, Contents) of
        ok ->
            case file:sync(Handle) of
                ok -> file:close(Handle);
                {error, _} = Error ->
                    _ = file:close(Handle),
                    Error
            end;
        {error, _} = Error ->
            _ = file:close(Handle),
            Error
    end.

is_executable_path(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mode = Mode}} -> Mode band 8#111 =/= 0;
        _ -> false
    end.

linux_process_identity(Pid) ->
    case {file:read_file("/proc/sys/kernel/random/boot_id"),
          file:read_file("/proc/self/stat")} of
        {{ok, BootId}, {ok, _SelfStat}} ->
            linux_target_process_identity(Pid, BootId);
        {{error, Reason}, _} ->
            {error, describe(Reason)};
        {_, {error, Reason}} ->
            {error, describe(Reason)}
    end.

linux_target_process_identity(Pid, BootId) ->
    StatPath = "/proc/" ++ integer_to_list(Pid) ++ "/stat",
    case file:read_file(StatPath) of
        {error, enoent} ->
            {ok, process_absent};

        % The target can exit after procfs opens its stat entry. ESRCH on
        % this target read confirms absence, just as a missing entry does.
        {error, esrch} ->
            {ok, process_absent};
        {error, Reason} ->
            {error, describe(Reason)};
        {ok, Stat} ->
            linux_identity_from_stat(Stat, BootId)
    end.

linux_identity_from_stat(Stat, BootId) ->
    case binary:matches(Stat, <<")">>) of
        [] -> {error, <<"process stat is malformed">>};
        Matches ->
            {Closing, _} = lists:last(Matches),
            Suffix = binary:part(
                Stat,
                Closing + 1,
                byte_size(Stat) - Closing - 1
            ),
            Fields = string:lexemes(Suffix, " \t\r\n"),
            case length(Fields) >= 20 of
                true ->
                    Start = lists:nth(20, Fields),
                    Birth = <<"linux:", (string:trim(BootId))/binary,
                              ":", Start/binary>>,
                    {ok, {process_present, Birth}};
                false -> {error, <<"process stat has no birth time">>}
            end
    end.

darwin_process_identity(Pid) ->
    case run_capture_status(
        "/bin/ps",
        ["-p", integer_to_list(Pid), "-o", "lstart="],
        2000
    ) of
        {ok, 0, Output} ->
            Started = string:trim(Output),
            case Started of
                <<>> -> {error, <<"process has no birth time">>};
                _ -> {ok, {process_present,
                           <<"darwin:", Started/binary>>}}
            end;
        {ok, 1, <<>>} ->
            {ok, process_absent};
        {ok, Status, Output} ->
            {error, describe({exit_status, Status, Output})};
        {error, _} = Error -> Error
    end.

run_capture_status(Executable, Arguments, TimeoutMs) ->
    try
        Port = open_port(
            {spawn_executable, Executable},
            [binary, exit_status, use_stdio, stderr_to_stdout, hide,
             {args, Arguments}]
        ),
        collect_port_status(Port, [], TimeoutMs)
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

collect_port_status(Port, Chunks, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_port_status(Port, [Data | Chunks], TimeoutMs);
        {Port, {exit_status, Status}} ->
            {ok, Status, iolist_to_binary(lists:reverse(Chunks))}
    after TimeoutMs ->
        _ = safe_port_close(Port),
        {error, <<"operating-system helper timed out">>}
    end.

run_capture(Executable, Arguments, TimeoutMs) ->
    try
        Port = open_port(
            {spawn_executable, Executable},
            [binary, exit_status, use_stdio, stderr_to_stdout, hide,
             {args, Arguments}]
        ),
        collect_port(Port, [], TimeoutMs)
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

collect_port(Port, Chunks, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Chunks], TimeoutMs);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Chunks))};
        {Port, {exit_status, Status}} ->
            {error, describe({exit_status, Status,
                              iolist_to_binary(lists:reverse(Chunks))})}
    after TimeoutMs ->
        _ = safe_port_close(Port),
        {error, <<"operating-system helper timed out">>}
    end.

safe_port_close(Port) ->
    try port_close(Port) of
        true -> ok
    catch
        error:badarg -> ok
    end.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
