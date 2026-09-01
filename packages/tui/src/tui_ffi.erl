-module(tui_ffi).

-include_lib("kernel/include/file.hrl").

-export([read_prefix/2, read_bounded/2,
         system_time_ms/0, sha256/1, getenv/1,
         canonical_directory/1, canonical_path/1, path_exists/1,
         absolute_path/1,
         ensure_private_directory/1,
         try_launch_lock/1, release_launch_lock/1,
         read_regular_bounded/2, read_private_bounded/2,
         atomic_write_private/2, find_executable/1,
         is_executable_file/1, reserve_loopback_port/0,
         spawn_server/4, release_server_process/1, close_server_process/1,
         terminate_process_group/1, process_identity/1,
         current_log_tail/3]).

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

system_time_ms() ->
    erlang:system_time(millisecond).

sha256(Bytes) ->
    crypto:hash(sha256, Bytes).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
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
                                    Resolved = string:trim(Output),
                                    case Resolved of
                                        <<>> -> {error, <<"realpath returned an empty path">>};
                                        _ -> {ok, Resolved}
                                    end;
                                {error, _} = Error -> Error
                            end
                    end
            end
    end.

canonical_path(PathBinary) ->
    Path = filename:absname(binary_to_list(PathBinary)),
    case realpath_executable() of
        {error, _} = Error -> Error;
        {ok, Realpath} ->
            case run_capture(Realpath, [Path], 5000) of
                {ok, Output} ->
                    Resolved = string:trim(Output),
                    case Resolved of
                        <<>> -> {error, <<"realpath returned an empty path">>};
                        _ -> {ok, Resolved}
                    end;
                {error, _} = Error -> Error
            end
    end.

path_exists(PathBinary) ->
    case file:read_link_info(binary_to_list(PathBinary), [{time, posix}]) of
        {ok, _} -> true;
        {error, _} -> false
    end.

absolute_path(Path) ->
    try
        {ok, unicode:characters_to_binary(
            filename:absname(binary_to_list(Path))
        )}
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

ensure_private_directory(PathBinary) ->
    case os:type() of
        {unix, darwin} -> ensure_private_unix(PathBinary);
        {unix, linux} -> ensure_private_unix(PathBinary);
        _ -> {error, <<"automatic local startup is supported only on macOS and Linux">>}
    end.

ensure_private_unix(PathBinary) ->
    Path = binary_to_list(PathBinary),
    case filelib:ensure_dir(filename:join(Path, ".loom-private")) of
        ok ->
            case file:read_link_info(Path, [{time, posix}]) of
                {ok, #file_info{type = directory, uid = Uid}} ->
                    case current_uid() of
                        {ok, Uid} ->
                            case file:change_mode(Path, 8#700) of
                                ok -> {ok, nil};
                                {error, Reason} -> {error, describe(Reason)}
                            end;
                        {ok, _Other} ->
                            {error, describe({not_owned_by_current_user, Path})};
                        {error, _} = Error -> Error
                    end;
                {ok, #file_info{type = Type}} ->
                    {error, describe({state_path_is_not_a_directory, Type, Path})};
                {error, Reason} ->
                    {error, describe(Reason)}
            end;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

try_launch_lock(PathBinary) ->
    Path = binary_to_list(PathBinary),
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

read_regular_bounded(Path, Limit) ->
    read_bounded(Path, Limit).

read_private_bounded(PathBinary, Limit) ->
    Path = binary_to_list(PathBinary),
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, uid = Uid, mode = Mode}} ->
            case current_uid() of
                {ok, Uid} when Mode band 8#077 =:= 0 ->
                    read_bounded(PathBinary, Limit);
                {ok, Uid} ->
                    {error, <<"file is accessible to other users">>};
                {ok, _Other} ->
                    {error, <<"file is not owned by the current user">>};
                {error, _} = Error -> Error
            end;
        {ok, _} ->
            {error, <<"path is not a regular file">>};
        {error, Reason} ->
            {error, describe(Reason)}
    end.

atomic_write_private(PathBinary, Contents) ->
    Path = binary_to_list(PathBinary),
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
    Candidate = binary_to_list(CandidateBinary),
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

is_executable_file(Path) ->
    is_executable_path(binary_to_list(Path)).

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
    Executable = binary_to_list(ExecutableBinary),
    Arguments = lists:map(fun binary_to_list/1, ArgumentBinaries),
    Working = filename:absname(binary_to_list(WorkingBinary)),
    Log = filename:absname(binary_to_list(LogBinary)),
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
    Path = binary_to_list(PathBinary),
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Modified}}
          when Modified * 1000 >= StartedAtMs - 1000 ->
            case file:open(Path, [read, binary, raw]) of
                {ok, Handle} ->
                    Offset = erlang:max(0, Size - Limit),
                    _ = file:position(Handle, Offset),
                    Result = case file:read(Handle, Limit) of
                        {ok, Data} -> {ok, string:trim(Data)};
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
    {ok, binary_to_list(Path)}.

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
            {ok, "/usr/bin/lockf",
             ["-t", "0", Path, "/bin/sh", "-p", "-c", Script]};
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
