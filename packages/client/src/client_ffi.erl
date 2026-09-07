%% The client package's one Erlang shim (docs/gleam-style.md Part III:
%% one flat module per package). Every function here is reached only
%% through client/internal/ffi_os.gleam, which documents the why; this
%% file owns the how. The module doubles as the gen_event handler that
%% wait_for_sigterm/0 swaps into erl_signal_server, so the signal relay
%% needs no second module.
-module(client_ffi).

-export([system_time_ms/0, unique_positive_integer/0, find_executable/1,
         wait_for_sigterm/0, halt/1, constant_time_equal/2,
         create_exclusive_private_file/2, platform/0,
         terminate_supervisor/2, code_root_dir/0, erts_version/0,
         inflate_gzip/2, run_capture/3]).

%% gen_event callbacks (the SIGTERM relay).
-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

system_time_ms() ->
    erlang:system_time(millisecond).

unique_positive_integer() ->
    erlang:unique_integer([positive, monotonic]).

%% os:type/0 and erlang:system_info(system_architecture) as a raw pair.
%% Both are ambient facts of the running system with no pure answer, and
%% both are fixed for the life of the node -- which is what the system
%% prompt's byte-stability contract needs. No normalization happens here:
%% turning {unix, darwin} and "aarch64-apple-darwin23" into "macos/arm64"
%% is a decision, and decisions belong in Gleam.
platform() ->
    {_Family, Name} = os:type(),
    {atom_to_binary(Name, utf8),
     unicode:characters_to_binary(erlang:system_info(system_architecture))}.

%% code:root_dir/0 and erlang:system_info(version), each as a binary.
%% Both name the installation the emulator resolved for itself at boot:
%% for a release, root_dir is the unpacked release tree; otherwise it is
%% the OTP installation erl came from. Neither is normalized and neither
%% is joined into a path here -- client/install decides what lives where,
%% because that is a decision and decisions belong in Gleam.
code_root_dir() ->
    unicode:characters_to_binary(code:root_dir()).

erts_version() ->
    unicode:characters_to_binary(erlang:system_info(version)).

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

%% Runs one host executable to completion with a deadline, answering
%% {ok, {Status, Stdout}}. Reached only through client/secrets, which
%% documents why a host command resolves a credential at all.
%%
%% spawn_executable with {args, _} keeps every argument whole: no shell
%% parses this, so nothing in an operator's argv is split or expanded.
%% stderr stays inherited -- open_port can only merge it into stdout, and
%% a merged stream would let a helper's chatter become part of a
%% credential.
run_capture(Executable, Args, TimeoutMs) ->
    Argv = [binary_to_list(A) || A <- Args],
    try erlang:open_port({spawn_executable, binary_to_list(Executable)},
                         [binary, exit_status, eof, hide, {args, Argv}]) of
        Port ->
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            capture_loop(Port, Deadline, [], eof_pending, running)
    catch
        _:_ -> {error, <<"the command could not be started">>}
    end.

%% The deadline covers the whole run, not the gap between two chunks, so
%% the remaining budget is recomputed on every chunk. A child that
%% overruns is killed rather than merely abandoned: an unreaped
%% credential helper holding a vault session open is exactly what the
%% bound exists to prevent.
%%
%% Both eof and exit_status must arrive before the output is believed.
%% exit_status alone says the child is gone, not that its writes have been
%% delivered: OTP orders eof against exit_status and nothing else, so
%% returning on exit_status could cut a multi-chunk credential -- a
%% several-kilobyte JWT arrives in more than one pipe buffer -- into a
%% shorter string that still looks like a valid secret. eof is the point
%% at which the pipe has been read to its end. The two arrive in either
%% order, so each is recorded and only the second one finishes the run,
%% still under the one deadline.
capture_loop(Port, Deadline, Acc, Eof, Status) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Chunk}} ->
            capture_loop(Port, Deadline, [Chunk | Acc], Eof, Status);
        {Port, eof} ->
            capture_step(Port, Deadline, Acc, eof_seen, Status);
        {Port, {exit_status, Code}} ->
            capture_step(Port, Deadline, Acc, Eof, {exited, Code})
    after Remaining ->
        kill_capture(Port),
        {error, <<"the command did not finish in time">>}
    end.

%% The join: finish once both halves are in hand, and otherwise go back to
%% waiting for the one that is missing.
capture_step(Port, _Deadline, Acc, eof_seen, {exited, Code}) ->
    capture_done(Port, Acc, Code);
capture_step(Port, Deadline, Acc, Eof, Status) ->
    capture_loop(Port, Deadline, Acc, Eof, Status).

%% The eof option keeps the port open past the end of the child's output,
%% so this end is closed here rather than by the emulator.
capture_done(Port, Acc, Code) ->
    close_capture(Port),
    Output = iolist_to_binary(lists:reverse(Acc)),
    case unicode:characters_to_binary(Output, utf8, utf8) of
        Text when is_binary(Text) -> {ok, {Code, Text}};
        _NotUtf8 -> {error, <<"the command's output is not UTF-8">>}
    end.

%% SIGKILL first, then close: closing alone only drops this end of the
%% pipe, and the child may go on running. The drain that follows keeps a
%% late port message out of the booting process's mailbox.
%%
%% The signal reaches the direct child only. A helper that forks leaves
%% grandchildren alive past the deadline, because open_port offers no
%% session or process-group option and the only ways to get one -- a shell
%% wrapper, or an argv prefixed with setsid -- would put a shell or a
%% second program between the operator's argv and the process that runs
%% it, which this module exists not to do. The residual is accepted for
%% the same reasons broker_ffi.erl's kill accepts it: the operator chose
%% the helper, and the harness's own bound is still enforced because the
%% capture returns and the port is closed regardless of what the
%% grandchildren do.
kill_capture(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} when is_integer(OsPid), OsPid > 1 ->
            os:cmd("kill -KILL " ++ integer_to_list(OsPid));
        _Gone -> ok
    end,
    close_capture(Port).

%% Closing an already-closed port raises, and a port that closed itself is
%% the ordinary case here, so the badarg is the expected answer rather
%% than a fault. The drain keeps a late port message out of the caller's
%% mailbox either way.
close_capture(Port) ->
    try erlang:port_close(Port) of
        true -> ok
    catch
        _:_ -> ok
    end,
    flush_capture(Port).

flush_capture(Port) ->
    receive
        {Port, _Message} -> flush_capture(Port)
    after 0 -> ok
    end.

%% Replaces the default erl_signal_handler (whose sigterm response is an
%% immediate init:stop()) with this module, pointed at the caller, then
%% blocks until the relay delivers the signal. A failed swap (some other
%% code already replaced the handler) leaves nothing to wait on, so it
%% falls through to the same receive and the process simply waits until
%% the VM is stopped from outside — the pre-relay behavior.
wait_for_sigterm() ->
    ok = os:set_signal(sigterm, handle),
    _ = gen_event:swap_handler(erl_signal_server,
                               {erl_signal_handler, []},
                               {client_ffi, self()}),
    receive loom_sigterm -> nil end.

halt(Code) ->
    erlang:halt(Code).

%% sys:terminate/3 against a running OTP supervisor: the only graceful
%% external stop a supervisor offers, and the one gleam_otp's
%% static_supervisor does not wrap. The supervisor answers the system
%% message before it begins terminating its children, so `ok` means the
%% shutdown is under way rather than finished. Every failure -- an
%% already-dead pid, a process that answers no system messages, a
%% shutdown that outran the timeout -- collapses to {error, nil}, because
%% the caller's recourse is to kill either way.
terminate_supervisor(Pid, TimeoutMs) ->
    try sys:terminate(Pid, shutdown, TimeoutMs) of
        ok -> {ok, nil};
        _Other -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.

%% crypto:hash/2 (sha256) over each operand followed by
%% crypto:hash_equals/2 on the two fixed-size digests -- the bearer
%% check's presented side is attacker-controlled length, unlike
%% broker_ffi's fixed-32-byte tokens, so comparing raw bytes would let
%% hash_equals's length-mismatch fast path leak the presented length via
%% timing. Hashing first means the comparison never branches on the
%% input length at all: every call, right or wrong, compares two 32-byte
%% sha256 digests.
constant_time_equal(A, B) when is_bitstring(A), is_bitstring(B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).

%% file:write_file/3 with the exclusive option (O_EXCL: refuses rather
%% than follows a symlink or truncates an existing file) followed by
%% file:change_mode/2 -- the same "create exclusively, then tighten"
%% shape broker_ffi:write_private_file/3 uses. Errors of every kind
%% collapse to {error, nil}: the caller's token-file recourse is
%% identical whichever step failed.
create_exclusive_private_file(Path, Bytes) ->
    try
        PathList = unicode:characters_to_list(Path),
        ok = file:write_file(PathList, Bytes, [exclusive, raw]),
        ok = file:change_mode(PathList, 8#600),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% zlib inflate of a gzip stream, bounded by Limit output bytes.
%%
%% The bound is the whole point: an extension archive is untrusted input
%% and a decompression bomb is a handful of bytes on the wire. safeInflate
%% hands back one chunk per call rather than the whole stream, so the loop
%% can compare the running output size against Limit after every chunk and
%% abandon the stream the moment it goes over -- the bomb is never
%% materialised, and the caller learns which cap it hit rather than losing
%% the node to an out-of-memory kill. inflateInit/2 with a window bits of
%% 31 selects the gzip wrapper (15 window bits + 16), so the header and the
%% trailing CRC are checked by zlib rather than by us.
%%
%% Every zlib failure -- a bad header, a corrupt deflate block, a CRC that
%% does not match -- raises, and all of them collapse to stream_corrupt:
%% the caller's recourse is identical in each case, which is to refuse the
%% archive.
inflate_gzip(Bytes, Limit) when is_binary(Bytes), is_integer(Limit) ->
    Z = zlib:open(),
    try
        zlib:inflateInit(Z, 31),
        inflate_bounded(Z, Bytes, Limit, 0, [])
    catch
        _:_ -> {error, stream_corrupt}
    after
        zlib:close(Z)
    end.

%% Input is handed to safeInflate on the first call only; every later call
%% passes <<>> so zlib drains what it already holds.
inflate_bounded(Z, Input, Limit, Written, Acc) ->
    case zlib:safeInflate(Z, Input) of
        {continue, Output} ->
            inflate_more(Z, Limit, Written + iolist_size(Output),
                         [Acc, Output]);
        {finished, Output} ->
            inflate_done(Limit, Written + iolist_size(Output), [Acc, Output])
    end.

inflate_more(Z, Limit, Written, Acc) when Written =< Limit ->
    inflate_bounded(Z, <<>>, Limit, Written, Acc);
inflate_more(_Z, _Limit, _Written, _Acc) ->
    {error, output_too_large}.

inflate_done(Limit, Written, Acc) when Written =< Limit ->
    {ok, iolist_to_binary(Acc)};
inflate_done(_Limit, _Written, _Acc) ->
    {error, output_too_large}.

%% --- gen_event callbacks ---------------------------------------------------
%% State is the pid waiting in wait_for_sigterm/0. Swap-installed
%% handlers receive {NewArgs, OldState}; direct installs the bare pid.

init({Pid, _OldState}) when is_pid(Pid) -> {ok, Pid};
init(Pid) when is_pid(Pid) -> {ok, Pid}.

handle_event(sigterm, Pid) ->
    Pid ! loom_sigterm,
    {ok, Pid};
handle_event(_Signal, Pid) ->
    %% Other relayed signals (sigusr1, ...) are ignored rather than
    %% given the old default behavior; the server's contract is
    %% SIGTERM-only.
    {ok, Pid}.

handle_call(_Request, Pid) -> {ok, ok, Pid}.
handle_info(_Info, Pid) -> {ok, Pid}.
terminate(_Args, _Pid) -> ok.
code_change(_OldVsn, Pid, _Extra) -> {ok, Pid}.
