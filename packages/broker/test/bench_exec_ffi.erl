%% Test-only Erlang shims for the exec-pool benchmark (never shipped in src).
%%
%% The benchmark has to observe things the BEAM does not expose through
%% Gleam: a microsecond monotonic clock, the OS processes a helper pool
%% leaves behind, a helper's resident memory, and a way to stop a helper
%% process the way a hung kernel or a debugger would. Every one of them is
%% a read of /proc or a `kill(1)`, so none is reachable from the pure
%% packages, and none belongs in `src`.
-module(bench_exec_ffi).

-export([getenv/1, now_us/0, system_time_ns/0, close_port_of/1, unique/0, vm_counts/0, vm_settled_memory/0,
         helper_os_pids/0, busy_helper_os_pid/1, proc_tree/1, signal/2,
         census/1]).

%% The value of an environment variable, or `{error, nil}` when it is not
%% set. A Gleam `Result(String, Nil)`.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Microseconds on the monotonic clock since this node started. The raw
%% monotonic clock may be negative, and a latency probe that folds readings
%% with a zero seed would then lose its maximum; counting from node start
%% keeps every reading non-negative. Only differences are meaningful.
now_us() ->
    erlang:convert_time_unit(
      erlang:monotonic_time() - erlang:system_info(start_time),
      native, microsecond).

%% Nanoseconds on the wall clock, which is the clock `date +%s%N` reads in a
%% child. A test that compares a timestamp written by a payload with one taken
%% here has to use the same clock on both sides, and this is it.
system_time_ns() ->
    os:system_time(nanosecond).

%% Closes the port this node holds to the process with this OS pid, from a
%% process that is not the port's owner. The owner finds out the way it would
%% if the port had failed under it: its next write is refused, and no exit
%% status is ever delivered. `{error, nil}` when no such port is held.
close_port_of(OsPid) ->
    Ports = [Port || Port <- erlang:ports(),
                     {os_pid, Pid} <- [erlang:port_info(Port, os_pid)],
                     Pid =:= OsPid],
    case Ports of
        [Port] -> erlang:port_close(Port), {ok, nil};
        _ -> {error, nil}
    end.

%% A positive integer no other call in this node has returned.
unique() ->
    erlang:unique_integer([positive]).

%% Ports, processes and total allocated bytes, read together. A leak
%% census compares two of these, so the three must come from one instant.
vm_counts() ->
    {erlang:system_info(port_count), erlang:system_info(process_count),
     erlang:memory(total)}.

%% Total allocated bytes after every process has been collected, so that a
%% before/after pair measures what is retained rather than what is garbage
%% awaiting its turn.
vm_settled_memory() ->
    [erlang:garbage_collect(Pid) || Pid <- erlang:processes()],
    erlang:memory(total).

%% OS pids of the ports this node holds open to a `loom-exec` process.
%% Ports that are not OS processes report `undefined` and are skipped.
%% The helper is spawned as `/bin/sh -c 'exec 3<policy loom-exec'`, so
%% once the shell has exec'd, the port's OS pid is the helper's.
helper_os_pids() ->
    [Pid || Port <- erlang:ports(),
            {os_pid, Pid} <- [erlang:port_info(Port, os_pid)],
            is_integer(Pid),
            binary:match(cmdline(Pid), <<"loom-exec">>) =/= nomatch].

%% The one helper, outside `Exclude`, that currently has a child process:
%% the helper running an execution. `{error, nil}` when none is, or when
%% several are. `Exclude` lets a probe ignore helpers an earlier probe left
%% behind, which would otherwise make "the busy one" ambiguous.
busy_helper_os_pid(Exclude) ->
    Table = table(),
    Busy = [Pid || Pid <- helper_os_pids() -- Exclude,
                   lists:any(fun({_, Ppid, _, _, _}) -> Ppid =:= Pid end,
                             Table)],
    case Busy of
        [Only] -> {ok, Only};
        _ -> {error, nil}
    end.

%% The process `Root` and all its descendants, as `{Pid, Comm, RssKb}`.
proc_tree(Root) ->
    Table = table(),
    Members = descend([Root], Table, []),
    [{Pid, Comm, Rss} || {Pid, _, Comm, _, Rss} <- Table,
                         lists:member(Pid, Members)].

descend([], _Table, Seen) ->
    Seen;
descend([Pid | Rest], Table, Seen) ->
    case lists:member(Pid, Seen) of
        true -> descend(Rest, Table, Seen);
        false ->
            Children = [C || {C, Ppid, _, _, _} <- Table, Ppid =:= Pid],
            descend(Rest ++ Children, Table, [Pid | Seen])
    end.

%% Sends a named signal ("STOP", "CONT", "KILL") to an OS pid. Nothing
%% reaches the BEAM's own port machinery, which is the point: the helper
%% must see the signal the way a wedged host would deliver it.
signal(Pid, Name) ->
    os:cmd("kill -" ++ binary_to_list(Name) ++ " " ++ integer_to_list(Pid)),
    nil.

%% Every process whose command line contains one of the markers, as
%% `{Pid, Comm, Cmdline}`.
census(Markers) ->
    [{Pid, Comm, Cmd} || {Pid, _, Comm, Cmd, _} <- table(),
                         matches(Cmd, Markers)].

matches(Cmd, Markers) ->
    lists:any(fun(M) -> binary:match(Cmd, M) =/= nomatch end, Markers).

%% One row per readable process: `{Pid, Ppid, Comm, Cmdline, RssKb}`.
%% A process can exit between the directory listing and the reads; such a
%% row is skipped rather than reported half-read.
table() ->
    {ok, Names} = file:list_dir("/proc"),
    lists:filtermap(fun row/1, Names).

row(Name) ->
    try
        Pid = list_to_integer(Name),
        {ok, Stat} = file:read_file("/proc/" ++ Name ++ "/stat"),
        {Comm, Ppid} = parse_stat(Stat),
        {true, {Pid, Ppid, Comm, cmdline(Pid), rss_kb(Pid)}}
    catch
        _:_ -> false
    end.

%% `pid (comm) state ppid ...`, where comm may itself contain spaces and
%% parentheses, so the split is on the last closing parenthesis.
parse_stat(Stat) ->
    Open = binary:match(Stat, <<"(">>),
    {Start, _} = Open,
    Close = last_paren(Stat),
    Comm = binary:part(Stat, Start + 1, Close - Start - 1),
    Rest = binary:part(Stat, Close + 2, byte_size(Stat) - Close - 2),
    [_State, Ppid | _] = binary:split(Rest, <<" ">>, [global]),
    {Comm, binary_to_integer(Ppid)}.

last_paren(Stat) ->
    Matches = binary:matches(Stat, <<")">>),
    {Pos, _} = lists:last(Matches),
    Pos.

%% The command line with its NUL separators shown as spaces. Empty for a
%% kernel thread or a process that has gone.
cmdline(Pid) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/cmdline",
    case file:read_file(Path) of
        {ok, Bytes} ->
            Spaced = binary:replace(Bytes, <<0>>, <<" ">>, [global]),
            string:trim(Spaced, trailing, " ");
        {error, _} -> <<>>
    end.

%% VmRSS in kilobytes, 0 for a process with no address space of its own.
rss_kb(Pid) ->
    Path = "/proc/" ++ integer_to_list(Pid) ++ "/status",
    case file:read_file(Path) of
        {ok, Status} ->
            case re:run(Status, <<"VmRSS:\\s+(\\d+) kB">>,
                        [{capture, all_but_first, binary}]) of
                {match, [Kb]} -> binary_to_integer(Kb);
                nomatch -> 0
            end;
        {error, _} -> 0
    end.
