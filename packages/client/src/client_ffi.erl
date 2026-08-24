%% The client package's one Erlang shim (docs/gleam-style.md Part III:
%% one flat module per package). Every function here is reached only
%% through client/internal/ffi_os.gleam, which documents the why; this
%% file owns the how. The module doubles as the gen_event handler that
%% wait_for_sigterm/0 swaps into erl_signal_server, so the signal relay
%% needs no second module.
-module(client_ffi).

-export([system_time_ms/0, unique_positive_integer/0, find_executable/1,
         wait_for_sigterm/0, halt/1, constant_time_equal/2,
         create_exclusive_private_file/2]).

%% gen_event callbacks (the SIGTERM relay).
-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

system_time_ms() ->
    erlang:system_time(millisecond).

unique_positive_integer() ->
    erlang:unique_integer([positive, monotonic]).

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
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
