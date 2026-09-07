-module(tui_ffi).

%% The terminal's own four actions. Bounded file reads, locks, process
%% identity and launch are shared with the daemon and live in
%% `host_bootstrap_ffi`, which `host/bootstrap` declares directly; nothing
%% here forwards to it.
-export([silence_logger/0, run_forwarding/2, halt/1, read_console_reply/1]).

silence_logger() ->
    ok = logger:set_primary_config(level, none),
    nil.

%% Runs one executable to completion, forwarding everything it writes to this
%% process's own stdout as it arrives, and answers with its exit status. Used
%% by `loom ext`, which is a passthrough to `loomd` rather than a terminal
%% application: nothing here draws a frame, so the child's output is the
%% output. `stderr_to_stdout` because a passthrough that reordered the two
%% streams would be worse than one that interleaves them as the child did.
run_forwarding(ExecutableBinary, ArgumentBinaries) ->
    Executable = unicode:characters_to_list(ExecutableBinary),
    Arguments = lists:map(fun unicode:characters_to_list/1, ArgumentBinaries),
    try
        Port = open_port(
            {spawn_executable, Executable},
            [binary, exit_status, use_stdio, stderr_to_stdout, hide,
             {args, Arguments}]
        ),
        forward_loop(Port)
    catch
        Class:Reason -> {error, describe({Class, Reason})}
    end.

forward_loop(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            forward_loop(Port);
        {Port, {exit_status, Status}} ->
            {ok, Status}
    end.

%% Exits the whole VM with a status. The launcher has no supervision tree to
%% unwind when it is acting as a passthrough, and the caller's exit code is
%% the whole point of the passthrough.
halt(Code) ->
    erlang:halt(Code).

%% Asks the person at the terminal one question and answers with the line
%% they typed. A caller with no terminal on stdin is refused rather than
%% blocked: `loom sessions rm` in a pipeline must fail asking for --yes
%% instead of waiting forever on input that is not coming.
read_console_reply(PromptBinary) ->
    case prim_tty:isatty(stdin) of
        true ->
            case io:get_line(unicode:characters_to_list(PromptBinary)) of
                eof -> {error, <<"no reply on standard input">>};
                {error, Reason} -> {error, describe(Reason)};
                Line -> {ok, unicode:characters_to_binary(Line)}
            end;
        _ ->
            {error, <<"standard input is not a terminal">>}
    end.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
