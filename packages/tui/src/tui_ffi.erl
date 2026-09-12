-module(tui_ffi).

%% The terminal's own four actions. Bounded file reads, locks, process
%% identity and launch are shared with the daemon and live in
%% `host_bootstrap_ffi`, which `host/bootstrap` declares directly; nothing
%% here forwards to it.
-export([silence_logger/0, run_forwarding/2, halt/1, read_console_reply/1,
    herdr_exchange/3]).

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
%% instead of waiting forever on input that is not coming. The terminal
%% question goes through the documented `{terminal, boolean()}` option of
%% io:getopts/1 rather than prim_tty:isatty/1, which is a kernel internal
%% carrying no compatibility promise across releases.
read_console_reply(PromptBinary) ->
    case proplists:get_value(terminal, io:getopts(standard_io), false) of
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

%% One request/response exchange with the Herdr client daemon over a
%% unix-domain socket. A `{local, Path}' address is the only unix-domain
%% transport OTP exposes, and the deadline on each phase is the whole
%% reason the reporter exists: a connect to a stale socket path must cost
%% the caller at most the timeout, so connect, send and receive each
%% carry one rather than trusting a kernel default. The reply is bounded at
%% one line — the daemon answers a report with a short acknowledgement and
%% nothing else — and a close before any byte is an error, because the only
%% answer the reporter acts on is that the daemon did not take the report.
herdr_exchange(Path, Payload, TimeoutMs) ->
    %% The socket address goes in the positional Address argument alone.
    %% Passing `{ifaddr, {local, Path}}' in the options as well makes
    %% gen_tcp bind it twice and refuse with eaddrinuse.
    Address = {local, unicode:characters_to_list(Path)},
    case gen_tcp:connect(Address, 0,
        [binary, {packet, line}, {active, false}], TimeoutMs) of
        {ok, Socket} ->
            Result = exchange_on(Socket, Payload, TimeoutMs),
            gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

exchange_on(Socket, Payload, TimeoutMs) ->
    case gen_tcp:send(Socket, Payload) of
        ok ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, Reply} -> {ok, Reply};
                {error, Reason} -> {error, describe(Reason)}
            end;
        {error, Reason} ->
            {error, describe(Reason)}
    end.
